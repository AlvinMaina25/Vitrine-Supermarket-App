-- =============================================================================
-- PHASE 7 - NOTIFICATIONS OUTBOX (BACKEND ONLY). NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005150000 (6L.2). One transaction. Section 0 refuses a second run.
--
-- ADDS
--   table public.notification_outbox   one row per (event, entity, channel); written by triggers
--   enqueue triggers (AFTER, SECURITY DEFINER, failure-tolerant) on:
--     orders                  INSERT                          -> order_created
--                             status change                   -> order_status_changed | order_delivered | order_refunded
--                             payment_status -> refunded      -> order_refunded
--     payment_transactions    INSERT/UPDATE to succeeded      -> payment_succeeded
--                             INSERT/UPDATE to failed         -> payment_failed
--   claim_notifications(p_limit)                   service_role ONLY  (FOR UPDATE SKIP LOCKED)
--   complete_notification(p_id, p_outcome, p_error) service_role ONLY (backoff; dead after 5)
--   admin_list_notifications(p_status, p_limit, p_offset)  authenticated, require_admin() inside
--   get_my_notifications(p_limit)                  authenticated, own rows, 5 columns only
--
-- DESIGN
--   * Outbox pattern. The trigger runs in the SAME transaction as the business change, so the
--     event commits or rolls back with it. A worker sends later; it is never part of the order.
--   * A failure while enqueueing is caught inside the trigger (a sub-transaction), logged as a
--     WARNING with the SQLSTATE only, and never blocks or rolls back the order or the payment.
--   * Idempotent: dedupe_key = event_type:entity_id:channel, UNIQUE. Enqueue is ON CONFLICT DO
--     NOTHING. 'sent' rows are immutable, so a replay can never send twice.
--   * entity_id: order id (order_created, order_delivered, order_refunded); payment transaction id
--     (payment_succeeded, payment_failed); a deterministic id for ONE status transition
--     (order_status_changed; md5 of order id + new status + history count), because an order has
--     many transitions and each must notify once.
--   * Stored: user_id + channel + ids. NEVER an email address, a phone number, a name, an amount,
--     or any payment detail. payload is a CHECK-enforced object holding only order_id and/or
--     transaction_id. The worker resolves the address at send time with the service role.
--   * Channels: email always; sms and whatsapp only when the customer has a phone number on their
--     profile when the event happens (the number itself is not copied).
--   * Statuses: pending, processing, sent, failed, skipped_not_configured, dead.
--       failed  = last attempt failed, will be retried (backoff 30s * 2^(attempts-1), cap 6h)
--       dead    = gave up (5 attempts, or a permanent error) - replay by hand, see docs
--       sent    = ONLY when a real provider accepted the message (the worker decides, never SQL)
--   * No API role (anon, authenticated, service_role) holds any privilege on the table, and RLS is
--     enabled with no policy. The only paths in are the four functions above.
--
-- DOES NOT: send anything, add UI, change set_order_status / apply_payment_outcome /
--   record_cod_payment / create_order, or touch any earlier table, policy or migration.
-- =============================================================================
begin;

-- 0. Preconditions ------------------------------------------------------------------------------
do $pre$
begin
  if to_regclass('public.orders') is null
     or to_regclass('public.order_status_history') is null
     or to_regclass('public.payment_transactions') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)') is null then
    raise exception 'Phase 7 precondition failed: apply migrations up to 20261005150000 first.';
  end if;
  if to_regclass('public.notification_outbox') is not null
     or to_regprocedure('public.claim_notifications(integer)') is not null then
    raise exception 'Phase 7 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. Table --------------------------------------------------------------------------------------
create table public.notification_outbox (
  id              uuid primary key default gen_random_uuid(),
  event_type      text not null,
  entity_id       uuid not null,
  user_id         uuid not null references auth.users (id) on delete cascade,
  channel         text not null,
  dedupe_key      text not null,
  payload         jsonb not null default '{}'::jsonb,
  status          text not null default 'pending',
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error      text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,

  constraint notification_outbox_dedupe_key_key unique (dedupe_key),
  constraint notification_outbox_event_type_check check (event_type in (
    'order_created', 'payment_succeeded', 'payment_failed',
    'order_status_changed', 'order_delivered', 'order_refunded')),
  constraint notification_outbox_channel_check check (channel in ('email', 'sms', 'whatsapp')),
  constraint notification_outbox_status_check check (status in (
    'pending', 'processing', 'sent', 'failed', 'skipped_not_configured', 'dead')),
  -- The key cannot drift from what it claims to be.
  constraint notification_outbox_dedupe_key_format
    check (dedupe_key = event_type || ':' || entity_id::text || ':' || channel),
  -- Ids only: an object whose only keys are order_id / transaction_id, each a uuid string.
  constraint notification_outbox_payload_ids_only check (
    jsonb_typeof(payload) = 'object'
    and (payload - 'order_id' - 'transaction_id') = '{}'::jsonb
    and (not (payload ? 'order_id') or payload ->> 'order_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    and (not (payload ? 'transaction_id') or payload ->> 'transaction_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
  constraint notification_outbox_attempts_range check (attempts between 0 and 5),
  constraint notification_outbox_last_error_length check (last_error is null or char_length(last_error) <= 200),
  constraint notification_outbox_sent_at_matches_status check ((status = 'sent') = (sent_at is not null))
);

comment on table public.notification_outbox is
  'Notification outbox. Written only by triggers; drained only by the service-role worker via claim_notifications/complete_notification. Holds user_id + channel + ids: no addresses, no amounts, no payment details. No API role has table privileges.';

create index notification_outbox_due_idx
  on public.notification_outbox (next_attempt_at, created_at)
  where status in ('pending', 'failed', 'processing');
create index notification_outbox_user_idx on public.notification_outbox (user_id, created_at desc);
create index notification_outbox_status_idx on public.notification_outbox (status, created_at desc);

-- 2. Lockdown: no API role touches the table ------------------------------------------------------
-- Supabase default privileges grant new public tables to anon/authenticated/service_role, so the
-- revoke is explicit. SECURITY DEFINER functions (owned by the migration role) are the only way in.
revoke all on public.notification_outbox from public, anon, authenticated, service_role;
alter table public.notification_outbox enable row level security;   -- no policy: deny by default

-- 3. Row guard: identity is immutable, 'sent' is final ---------------------------------------------
create function public.notification_outbox_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.status = 'sent' then
    raise exception 'A sent notification is final and cannot change.'
      using errcode = 'P0001', detail = 'notification_already_sent';
  end if;
  if (new.id, new.event_type, new.entity_id, new.user_id, new.channel, new.dedupe_key, new.payload, new.created_at)
     is distinct from
     (old.id, old.event_type, old.entity_id, old.user_id, old.channel, old.dedupe_key, old.payload, old.created_at) then
    raise exception 'The identity of a notification cannot change.'
      using errcode = 'P0001', detail = 'notification_identity_immutable';
  end if;
  return new;
end;
$$;

create trigger notification_outbox_guard
  before update on public.notification_outbox
  for each row execute function public.notification_outbox_guard();

-- 4. Internal enqueue (owner only: nobody can call it directly) ------------------------------------
create function public.notification_enqueue(
  p_event_type text,
  p_entity_id uuid,
  p_user_id uuid,
  p_payload jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_phone boolean;
  v_channel text;
begin
  select coalesce(nullif(btrim(p.phone), '') is not null, false) into v_has_phone
    from public.profiles p where p.id = p_user_id;
  v_has_phone := coalesce(v_has_phone, false);

  foreach v_channel in array array['email', 'sms', 'whatsapp'] loop
    if v_channel <> 'email' and not v_has_phone then
      continue;   -- nothing to send to; the number itself is never copied
    end if;
    insert into public.notification_outbox (event_type, entity_id, user_id, channel, dedupe_key, payload)
    values (p_event_type, p_entity_id, p_user_id, v_channel,
            p_event_type || ':' || p_entity_id::text || ':' || v_channel, p_payload)
    on conflict (dedupe_key) do nothing;
  end loop;
end;
$$;

-- 5. Trigger: orders ---------------------------------------------------------------------------------
create function public.notify_on_order_change()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_payload jsonb := jsonb_build_object('order_id', new.id);
  v_transitions bigint;
begin
  -- Everything below is best effort. Whatever goes wrong here must never block the order.
  begin
    if tg_op = 'INSERT' then
      perform public.notification_enqueue('order_created', new.id, new.user_id, v_payload);
      return new;
    end if;

    if new.status is distinct from old.status then
      if new.status = 'delivered' then
        perform public.notification_enqueue('order_delivered', new.id, new.user_id, v_payload);
      elsif new.status = 'refunded' then
        perform public.notification_enqueue('order_refunded', new.id, new.user_id, v_payload);
      elsif new.status <> 'paid' then   -- 'paid' is announced by payment_succeeded
        select count(*) into v_transitions from public.order_status_history h where h.order_id = new.id;
        perform public.notification_enqueue(
          'order_status_changed',
          md5(new.id::text || ':' || new.status::text || ':' || v_transitions::text)::uuid,
          new.user_id, v_payload);
      end if;
    end if;

    if new.payment_status = 'refunded' and old.payment_status is distinct from new.payment_status then
      perform public.notification_enqueue('order_refunded', new.id, new.user_id, v_payload);
    end if;
  exception when others then
    raise warning 'notification enqueue failed (sqlstate %)', sqlstate;
  end;
  return new;
end;
$$;

create trigger orders_notify_insert
  after insert on public.orders
  for each row execute function public.notify_on_order_change();

create trigger orders_notify_update
  after update of status, payment_status on public.orders
  for each row
  when (new.status is distinct from old.status or new.payment_status is distinct from old.payment_status)
  execute function public.notify_on_order_change();

-- 6. Trigger: payment_transactions --------------------------------------------------------------------
create function public.notify_on_payment_change()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
begin
  begin
    if new.status in ('succeeded', 'failed')
       and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      select o.user_id into v_user from public.orders o where o.id = new.order_id;
      if v_user is not null then
        perform public.notification_enqueue(
          case new.status when 'succeeded' then 'payment_succeeded' else 'payment_failed' end,
          new.id, v_user,
          jsonb_build_object('order_id', new.order_id, 'transaction_id', new.id));
      end if;
    end if;
  exception when others then
    raise warning 'notification enqueue failed (sqlstate %)', sqlstate;
  end;
  return new;
end;
$$;

create trigger payment_transactions_notify_insert
  after insert on public.payment_transactions
  for each row execute function public.notify_on_payment_change();

create trigger payment_transactions_notify_update
  after update of status on public.payment_transactions
  for each row
  when (new.status is distinct from old.status)
  execute function public.notify_on_payment_change();

-- 7. Worker: claim ---------------------------------------------------------------------------------------
-- Returns a jsonb array of { id, event_type, entity_id, user_id, channel, payload, attempts }.
-- attempts is incremented at claim time. A claim is a 10-minute lease: if the worker dies, the row
-- becomes claimable again (at-least-once delivery; see docs) unless it already used its 5 attempts.
create function public.claim_notifications(p_limit integer default 20)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_rows jsonb;
begin
  if p_limit is null or p_limit < 1 then
    raise exception 'A positive limit is required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  p_limit := least(p_limit, 50);

  -- A lease that expired with every attempt spent is finished, not retried.
  update public.notification_outbox n
     set status = 'dead', last_error = 'lease_expired'
   where n.status = 'processing' and n.next_attempt_at <= now() and n.attempts >= c_max_attempts;

  with picked as (
    select n.id
      from public.notification_outbox n
     where n.next_attempt_at <= now()
       and (n.status in ('pending', 'failed')
            or (n.status = 'processing' and n.attempts < c_max_attempts))
     order by n.next_attempt_at, n.created_at
     limit p_limit
       for update skip locked
  ), claimed as (
    update public.notification_outbox n
       set status = 'processing',
           attempts = n.attempts + 1,
           next_attempt_at = now() + interval '10 minutes'
      from picked
     where n.id = picked.id
    returning n.id, n.event_type, n.entity_id, n.user_id, n.channel, n.payload, n.attempts, n.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'event_type', c.event_type, 'entity_id', c.entity_id,
           'user_id', c.user_id, 'channel', c.channel, 'payload', c.payload,
           'attempts', c.attempts) order by c.created_at), '[]'::jsonb)
    into v_rows
    from claimed c;

  return v_rows;
end;
$$;

-- 8. Worker: complete -----------------------------------------------------------------------------------------
-- p_outcome: 'sent' | 'failed' (retryable) | 'skipped_not_configured' | 'dead' (permanent).
-- Only a 'processing' row can be completed. Replaying the same outcome is a no-op.
create function public.complete_notification(
  p_id uuid,
  p_outcome text,
  p_error text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_err text := nullif(left(btrim(regexp_replace(coalesce(p_error, ''), '[[:cntrl:]]', ' ', 'g')), 200), '');
  v_row public.notification_outbox%rowtype;
  v_target text;
begin
  if p_id is null or p_outcome is null
     or p_outcome not in ('sent', 'failed', 'skipped_not_configured', 'dead') then
    raise exception 'A notification and an outcome (sent, failed, skipped_not_configured or dead) are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_row from public.notification_outbox n where n.id = p_id for update;
  if not found then
    raise exception 'That notification could not be found.' using errcode = 'P0001', detail = 'notification_not_found';
  end if;

  -- Retryable failure on the last attempt becomes dead.
  v_target := case when p_outcome = 'failed' and v_row.attempts >= c_max_attempts then 'dead' else p_outcome end;

  if v_row.status = v_target then
    return jsonb_build_object('changed', false, 'status', v_row.status, 'attempts', v_row.attempts);
  end if;
  if v_row.status <> 'processing' then
    raise exception 'This notification is % and cannot become %.', v_row.status, v_target
      using errcode = 'P0001', detail = 'invalid_transition';
  end if;

  update public.notification_outbox n
     set status = v_target,
         sent_at = case when v_target = 'sent' then now() else null end,
         last_error = case when v_target = 'sent' then null else v_err end,
         next_attempt_at = case
           when v_target = 'failed'
             then now() + least(interval '30 seconds' * power(2, v_row.attempts - 1), interval '6 hours')
           else n.next_attempt_at end
   where n.id = v_row.id
  returning * into v_row;

  return jsonb_build_object('changed', true, 'status', v_row.status, 'attempts', v_row.attempts);
end;
$$;

-- 9. Admin read: ids and statuses only ---------------------------------------------------------------------------
create function public.admin_list_notifications(
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer;
  v_total bigint;
  v_rows jsonb;
  v_counts jsonb;
begin
  perform public.require_admin();

  if p_limit is null or p_limit < 1 or p_offset is null or p_offset < 0
     or (p_status is not null and p_status not in
         ('pending', 'processing', 'sent', 'failed', 'skipped_not_configured', 'dead')) then
    raise exception 'Invalid notification list arguments.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  v_limit := least(p_limit, 100);

  select count(*) into v_total from public.notification_outbox n where p_status is null or n.status = p_status;

  select coalesce(jsonb_object_agg(s.status, s.c), '{}'::jsonb) into v_counts
    from (select n.status, count(*) as c from public.notification_outbox n group by n.status) s;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id), '[]'::jsonb) into v_rows
    from (
      select n.id, n.event_type, n.entity_id, n.user_id, n.channel, n.status, n.attempts,
             n.next_attempt_at, n.last_error, n.created_at, n.sent_at
        from public.notification_outbox n
       where p_status is null or n.status = p_status
       order by n.created_at desc, n.id
       limit v_limit offset p_offset
    ) r;

  return jsonb_build_object('total', v_total, 'counts', v_counts, 'rows', v_rows);
end;
$$;

-- 10. Customer read: own history, five columns ---------------------------------------------------------------------
create function public.get_my_notifications(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'You must be signed in.' using errcode = '42501', detail = 'not_authorised';
  end if;
  if p_limit is null or p_limit < 1 then
    raise exception 'A positive limit is required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id), '[]'::jsonb) into v_rows
    from (
      select n.id, n.event_type, n.channel, n.status, n.created_at
        from public.notification_outbox n
       where n.user_id = v_user
       order by n.created_at desc, n.id
       limit least(p_limit, 100)
    ) r;
  return v_rows;
end;
$$;

-- 11. Function privileges -------------------------------------------------------------------------------------------------
revoke all on function public.notification_outbox_guard() from public, anon, authenticated, service_role;
revoke all on function public.notification_enqueue(text, uuid, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.notify_on_order_change() from public, anon, authenticated, service_role;
revoke all on function public.notify_on_payment_change() from public, anon, authenticated, service_role;

revoke all on function public.claim_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_notifications(integer) to service_role;
revoke all on function public.complete_notification(uuid, text, text) from public, anon, authenticated;
grant execute on function public.complete_notification(uuid, text, text) to service_role;

revoke all on function public.admin_list_notifications(text, integer, integer) from public, anon, service_role;
grant execute on function public.admin_list_notifications(text, integer, integer) to authenticated;
revoke all on function public.get_my_notifications(integer) from public, anon, service_role;
grant execute on function public.get_my_notifications(integer) to authenticated;

-- 12. Self-check (aborts the whole transaction if anything is off) -----------------------------------------------------------
do $chk$
declare
  v_role text;
  v_fn regprocedure;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.notification_outbox'::regclass) then
    raise exception 'Phase 7 self-check failed: RLS is not enabled on notification_outbox.';
  end if;
  foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
    if has_any_column_privilege(v_role, 'public.notification_outbox'::regclass, 'SELECT, INSERT, UPDATE, REFERENCES')
       or has_table_privilege(v_role, 'public.notification_outbox'::regclass, 'DELETE, TRUNCATE, TRIGGER') then
      raise exception 'Phase 7 self-check failed: % still holds a privilege on notification_outbox.', v_role;
    end if;
  end loop;
  if exists (select 1 from pg_class c, aclexplode(c.relacl) a
             where c.oid = 'public.notification_outbox'::regclass and a.grantee = 0) then
    raise exception 'Phase 7 self-check failed: PUBLIC holds a privilege on notification_outbox.';
  end if;
  if exists (select 1 from pg_policy p where p.polrelid = 'public.notification_outbox'::regclass) then
    raise exception 'Phase 7 self-check failed: notification_outbox must have no RLS policy.';
  end if;

  foreach v_fn in array array[
    'public.notification_enqueue(text,uuid,uuid,jsonb)'::regprocedure,
    'public.notify_on_order_change()'::regprocedure,
    'public.notify_on_payment_change()'::regprocedure,
    'public.notification_outbox_guard()'::regprocedure] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or has_function_privilege('service_role', v_fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 7 self-check failed: % must not be executable by any API role.', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'public.claim_notifications(integer)'::regprocedure,
    'public.complete_notification(uuid,text,text)'::regprocedure] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or not has_function_privilege('service_role', v_fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 7 self-check failed: % must be executable by service_role only.', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'public.admin_list_notifications(text,integer,integer)'::regprocedure,
    'public.get_my_notifications(integer)'::regprocedure] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('service_role', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 7 self-check failed: % must be executable by authenticated only.', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'public.notification_enqueue(text,uuid,uuid,jsonb)'::regprocedure,
    'public.notify_on_order_change()'::regprocedure,
    'public.notify_on_payment_change()'::regprocedure,
    'public.claim_notifications(integer)'::regprocedure,
    'public.complete_notification(uuid,text,text)'::regprocedure,
    'public.admin_list_notifications(text,integer,integer)'::regprocedure,
    'public.get_my_notifications(integer)'::regprocedure] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_fn and p.prosecdef
                     and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%public%pg_temp%')) then
      raise exception 'Phase 7 self-check failed: % is not SECURITY DEFINER with search_path = public, pg_temp.', v_fn;
    end if;
  end loop;

  if (select p.prosrc from pg_proc p where p.oid = 'public.admin_list_notifications(text,integer,integer)'::regprocedure)
     not like '%public.require_admin()%' then
    raise exception 'Phase 7 self-check failed: admin_list_notifications does not call require_admin().';
  end if;

  if (select count(*) from pg_trigger t
       where not t.tgisinternal
         and t.tgname in ('orders_notify_insert', 'orders_notify_update',
                          'payment_transactions_notify_insert', 'payment_transactions_notify_update',
                          'notification_outbox_guard')) <> 5 then
    raise exception 'Phase 7 self-check failed: expected 5 notification triggers.';
  end if;
end
$chk$;

commit;
