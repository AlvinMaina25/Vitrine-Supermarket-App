-- =============================================================================
-- PHASE 6E.1B-3 - status + notes in admin_list_customers() / admin_get_customer().
-- NOT APPLIED / NOT RUN anywhere. Apply once, after 20261004150000. One transaction.
-- Read-only: no table, column, policy or table grant is created or changed.
--
-- GATE CHANGE: both functions move from is_staff(auth.uid()) to require_admin().
--   Staff (non-admin) can no longer read customer details; admins only.
-- admin_list_customers: NEW 4th argument p_status (default null = all; 'active' | 'suspended';
--   anything else, including '' and wrong case, -> P0001 / invalid_arguments). Postgres treats a
--   changed argument list as a different function, so the old 3-argument version is DROPPED and
--   recreated with 4 arguments (grants re-applied below). Existing 3-argument calls still work.
--   Output: every existing field unchanged + 'status' per customer. 'total' respects the filter.
--   Notes are NOT in the list.
-- admin_get_customer: profile gets 'status'. New top-level keys 'notes' and 'notes_updated_at'
--   (next to profile/addresses/stats/recent_orders). notes is null when there is no row OR the
--   notes were cleared (stored ''); notes_updated_at is the row's updated_at, or null if no row.
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.admin_list_customers(text,integer,integer)') is null
     or to_regprocedure('public.admin_get_customer(uuid)') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regclass('public.customer_notes') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'profiles' and column_name = 'status') then
    raise exception 'Phase 6E.1B-3 precondition failed: apply 20261004120000 .. 20261004150000 first.';
  end if;
  if to_regprocedure('public.admin_list_customers(text,integer,integer,text)') is not null then
    raise exception 'Phase 6E.1B-3 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. admin_list_customers (3 args -> 4 args)
drop function public.admin_list_customers(text, integer, integer);

create function public.admin_list_customers(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 25,
  p_status text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pattern text;
  v_size integer;
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_admin();

  if p_page is null or p_page < 1 or p_page > 1000000
     or p_page_size is null or p_page_size < 1
     or (v_search is not null and char_length(v_search) > 100)
     or (p_status is not null and p_status not in ('active', 'suspended')) then
    raise exception 'Invalid customer list arguments (page >= 1, page_size >= 1, search up to 100 characters, status active or suspended).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_size := least(p_page_size, 100);

  if v_search is not null then
    v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  select count(*) into v_total
  from public.profiles p
  join auth.users u on u.id = p.id
  where not exists (select 1 from public.user_roles ur
                    where ur.user_id = p.id and ur.role in ('staff', 'admin'))
    and (p_status is null or p.status = p_status)
    and (v_pattern is null
         or p.full_name ilike v_pattern
         or u.email ilike v_pattern
         or p.phone ilike v_pattern);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pg.id,
           'name', pg.full_name,
           'email', pg.email,
           'phone', pg.phone,
           'status', pg.status,
           'created_at', pg.created_at,
           'order_count', a.c,
           'lifetime_spend_cents', a.s,
           'last_order_at', a.m
         ) order by pg.created_at desc, pg.id desc), '[]'::jsonb)
  into v_rows
  from (
    select p.id, p.full_name, u.email::text as email, p.phone, p.status, p.created_at
    from public.profiles p
    join auth.users u on u.id = p.id
    where not exists (select 1 from public.user_roles ur
                      where ur.user_id = p.id and ur.role in ('staff', 'admin'))
      and (p_status is null or p.status = p_status)
      and (v_pattern is null
           or p.full_name ilike v_pattern
           or u.email ilike v_pattern
           or p.phone ilike v_pattern)
    order by p.created_at desc, p.id desc
    limit v_size offset (p_page - 1) * v_size
  ) pg
  left join lateral (
    select count(*)::bigint as c,
           coalesce(sum(o.total_cents), 0)::bigint as s,
           max(o.placed_at) as m
    from public.orders o
    where o.user_id = pg.id and o.status <> 'cancelled'
  ) a on true;

  return jsonb_build_object('total', v_total, 'page', p_page, 'page_size', v_size, 'customers', v_rows);
end;
$$;

comment on function public.admin_list_customers(text, integer, integer, text) is
  'Phase 6E.1B-3. Admin-only (require_admin()), read-only customer list with search, status filter and paging. No notes.';

revoke all on function public.admin_list_customers(text, integer, integer, text) from public, anon, authenticated;
grant execute on function public.admin_list_customers(text, integer, integer, text) to authenticated;

-- 2. admin_get_customer (same signature, replaced in place)
create or replace function public.admin_get_customer(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile jsonb;
  v_addresses jsonb;
  v_stats jsonb;
  v_orders jsonb;
  v_notes text;
  v_notes_at timestamptz;
begin
  perform public.require_admin();

  if p_customer_id is null then
    raise exception 'A customer id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select jsonb_build_object('id', p.id, 'name', p.full_name, 'email', u.email::text,
                            'phone', p.phone, 'status', p.status, 'created_at', p.created_at)
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

  select nullif(n.notes, ''), n.updated_at
  into v_notes, v_notes_at
  from public.customer_notes n
  where n.customer_id = p_customer_id;

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
                            'stats', v_stats, 'recent_orders', v_orders,
                            'notes', v_notes, 'notes_updated_at', v_notes_at);
end;
$$;

comment on function public.admin_get_customer(uuid) is
  'Phase 6E.1B-3. Admin-only (require_admin()), read-only customer detail incl. status and internal notes.';

revoke all on function public.admin_get_customer(uuid) from public, anon, authenticated;
grant execute on function public.admin_get_customer(uuid) to authenticated;

-- 3. Self-check
do $check$
declare
  v_list constant text := 'public.admin_list_customers(text,integer,integer,text)';
  v_get constant text := 'public.admin_get_customer(uuid)';
  v_sig text;
begin
  foreach v_sig in array array[v_list, v_get] loop
    if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
               and (not p.prosecdef or p.provolatile <> 's'
                    or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
                    or p.prosrc not like '%require_admin()%' or p.prosrc like '%is_staff%')) then
      raise exception 'Phase 6E.1B-3 self-check failed: % is not STABLE SECURITY DEFINER / pinned search_path / require_admin gate.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'EXECUTE') or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
      raise exception 'Phase 6E.1B-3 self-check failed: % has wrong function privileges.', v_sig;
    end if;
  end loop;
  if to_regprocedure('public.admin_list_customers(text,integer,integer)') is not null then
    raise exception 'Phase 6E.1B-3 self-check failed: the old 3-argument admin_list_customers still exists.';
  end if;
end
$check$;

commit;
