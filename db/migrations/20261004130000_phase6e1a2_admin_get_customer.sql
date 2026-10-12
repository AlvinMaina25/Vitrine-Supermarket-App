-- =============================================================================
-- PHASE 6E.1A-2 - admin_get_customer(). NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261004120000 (admin_list_customers). One transaction. Read-only: no
-- table, column, policy or table grant is created or changed; no data is written.
--
-- Gate and customer definition are identical to admin_list_customers(): staff OR admin via
-- is_staff(auth.uid()); a "customer" is a profile with no staff/admin row in user_roles.
-- Email comes from auth.users.email only. Stats use the SAME definitions as the list:
-- order_count / lifetime_spend_cents / last_order_at ignore status 'cancelled' (last_order_at
-- is max(placed_at)).
-- Returns { profile, addresses, stats, recent_orders }.
--   recent_orders: the 10 newest orders (placed_at desc, id desc), cancelled ones INCLUDED
--   (this is history, status is shown); each has id, status, payment_status, total_cents and
--   created_at (= orders.placed_at, the same clock the stats use).
-- Unknown id, or the id of a staff/admin user -> P0001 / customer_not_found (after the gate).
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.admin_list_customers(text,integer,integer)') is null
     or to_regclass('public.addresses') is null then
    raise exception 'Phase 6E.1A-2 precondition failed: apply 20261004120000 (admin_list_customers) first.';
  end if;
  if to_regprocedure('public.admin_get_customer(uuid)') is not null then
    raise exception 'Phase 6E.1A-2 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

create or replace function public.admin_get_customer(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_profile jsonb;
  v_addresses jsonb;
  v_stats jsonb;
  v_orders jsonb;
begin
  if v_uid is null or not public.is_staff(v_uid) then
    raise exception 'You are not allowed to perform this admin action.'
      using errcode = '42501', detail = 'not_authorised';
  end if;

  if p_customer_id is null then
    raise exception 'A customer id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select jsonb_build_object('id', p.id, 'name', p.full_name, 'email', u.email::text,
                            'phone', p.phone, 'created_at', p.created_at)
  into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.id = p_customer_id
    and not exists (select 1 from public.user_roles ur
                    where ur.user_id = p.id and ur.role in ('staff', 'admin'));

  if v_profile is null then
    raise exception 'That customer could not be found.'
      using errcode = 'P0001', detail = 'customer_not_found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'label', a.label, 'full_name', a.full_name, 'phone', a.phone,
           'address_line_1', a.address_line_1, 'address_line_2', a.address_line_2,
           'city', a.city, 'county', a.county, 'postal_code', a.postal_code,
           'delivery_instructions', a.delivery_instructions,
           'is_default', a.is_default, 'created_at', a.created_at)
         order by a.is_default desc, a.created_at, a.id), '[]'::jsonb)
  into v_addresses
  from public.addresses a
  where a.user_id = p_customer_id;

  select jsonb_build_object('order_count', count(*)::bigint,
                            'lifetime_spend_cents', coalesce(sum(o.total_cents), 0)::bigint,
                            'last_order_at', max(o.placed_at))
  into v_stats
  from public.orders o
  where o.user_id = p_customer_id and o.status <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'status', r.status, 'payment_status', r.payment_status,
           'total_cents', r.total_cents, 'created_at', r.placed_at)
         order by r.placed_at desc, r.id desc), '[]'::jsonb)
  into v_orders
  from (
    select o.id, o.status, o.payment_status, o.total_cents, o.placed_at
    from public.orders o
    where o.user_id = p_customer_id
    order by o.placed_at desc, o.id desc
    limit 10
  ) r;

  return jsonb_build_object('profile', v_profile, 'addresses', v_addresses,
                            'stats', v_stats, 'recent_orders', v_orders);
end;
$$;

comment on function public.admin_get_customer(uuid) is
  'Phase 6E.1A-2. Staff/admin-only, read-only customer detail. Same gate and stats as admin_list_customers().';

revoke all on function public.admin_get_customer(uuid) from public, anon, authenticated;
grant execute on function public.admin_get_customer(uuid) to authenticated;

do $check$
declare v_sig constant text := 'public.admin_get_customer(uuid)';
begin
  if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
             and (not p.prosecdef or p.provolatile <> 's'
                  or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
    raise exception 'Phase 6E.1A-2 self-check failed: not STABLE SECURITY DEFINER with pinned search_path.';
  end if;
  if has_function_privilege('anon', v_sig, 'EXECUTE') or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
    raise exception 'Phase 6E.1A-2 self-check failed: function privileges are wrong.';
  end if;
end
$check$;

commit;
