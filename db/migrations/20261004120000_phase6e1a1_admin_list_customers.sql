-- =============================================================================
-- PHASE 6E.1A-1 - admin_list_customers(). NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261004110000. One transaction. Read-only: no table, column, policy or
-- table grant is created or changed; no data is written.
--
-- Gate: staff OR admin (public.is_staff, which includes admins), keyed to auth.uid().
--   NOTE: 6B.1 used require_admin() (admin only). This one is deliberately staff-wide, per the
--   Phase 6E.1A-1 brief. To make it admin-only, swap the gate for `perform public.require_admin();`.
-- Customers = profiles with NO staff/admin row in user_roles.
-- Email comes from auth.users.email (the only auth.users column read). Name/phone: profiles.
-- order_count / lifetime_spend_cents / last_order_at ignore orders with status 'cancelled'.
-- Arguments: p_search (<=100 chars, LIKE wildcards escaped, matches name/email/phone),
--   p_page >= 1 (1-based), p_page_size 1..100 (values above 100 are CAPPED to 100, not rejected).
-- Returns { total, page, page_size, customers: [...] }, newest profile first.
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.is_staff(uuid)') is null
     or to_regclass('public.profiles') is null or to_regclass('public.orders') is null
     or to_regclass('public.user_roles') is null then
    raise exception 'Phase 6E.1A-1 precondition failed: is_staff() / profiles / orders / user_roles missing.';
  end if;
  if to_regprocedure('public.admin_list_customers(text,integer,integer)') is not null then
    raise exception 'Phase 6E.1A-1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

create or replace function public.admin_list_customers(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pattern text;
  v_size integer;
  v_total bigint;
  v_rows jsonb;
begin
  if v_uid is null or not public.is_staff(v_uid) then
    raise exception 'You are not allowed to perform this admin action.'
      using errcode = '42501', detail = 'not_authorised';
  end if;

  if p_page is null or p_page < 1 or p_page > 1000000
     or p_page_size is null or p_page_size < 1
     or (v_search is not null and char_length(v_search) > 100) then
    raise exception 'Invalid customer list arguments (page >= 1, page_size >= 1, search up to 100 characters).'
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
    and (v_pattern is null
         or p.full_name ilike v_pattern
         or u.email ilike v_pattern
         or p.phone ilike v_pattern);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pg.id,
           'name', pg.full_name,
           'email', pg.email,
           'phone', pg.phone,
           'created_at', pg.created_at,
           'order_count', a.c,
           'lifetime_spend_cents', a.s,
           'last_order_at', a.m
         ) order by pg.created_at desc, pg.id desc), '[]'::jsonb)
  into v_rows
  from (
    select p.id, p.full_name, u.email::text as email, p.phone, p.created_at
    from public.profiles p
    join auth.users u on u.id = p.id
    where not exists (select 1 from public.user_roles ur
                      where ur.user_id = p.id and ur.role in ('staff', 'admin'))
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

comment on function public.admin_list_customers(text, integer, integer) is
  'Phase 6E.1A-1. Staff/admin-only, read-only customer list with server-side search and paging.';

revoke all on function public.admin_list_customers(text, integer, integer) from public, anon, authenticated;
grant execute on function public.admin_list_customers(text, integer, integer) to authenticated;

do $check$
declare v_sig constant text := 'public.admin_list_customers(text,integer,integer)';
begin
  if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
             and (not p.prosecdef or p.provolatile <> 's'
                  or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
    raise exception 'Phase 6E.1A-1 self-check failed: not STABLE SECURITY DEFINER with pinned search_path.';
  end if;
  if has_function_privilege('anon', v_sig, 'EXECUTE') or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
    raise exception 'Phase 6E.1A-1 self-check failed: function privileges are wrong.';
  end if;
end
$check$;

commit;
