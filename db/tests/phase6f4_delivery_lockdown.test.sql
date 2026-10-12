-- Phase 6F.4 test: delivery configuration lockdown. NOT RUN on a real Supabase.
-- Needs migrations up to 20261005030000 applied. Run as postgres/owner, as ONE query, SEPARATELY
-- from the migration. Everything is rolled back at the end. Fixtures carry the marker 'T6F4'.
-- Users are simulated with SET LOCAL ROLE + request.jwt.* settings (stub auth, as in the other tests).
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

create or replace function pg_temp.d(n integer) returns date language sql stable as $$
  select ((now() at time zone 'Africa/Nairobi')::date + n) $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f400000' || lpad(n::text, 4, '0'))::uuid $$;

create or replace function pg_temp.run(k text, r text, uid uuid, q text) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then '' else json_build_object('sub', uid, 'role', r)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  perform set_config('request.jwt.claim.role', r, true);
  begin
    execute format('set local role %I', r);
    execute q into v_res;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_res values (k, v_res, v_err, v_state, v_detail)
  on conflict on constraint t_res_pkey do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end $$;

create or replace function pg_temp.state(k text) returns text language sql as $$
  select state from t_res where t_res.k = state.k and t_res.err is not null $$;

create or replace function pg_temp.res(k text) returns text language sql as $$
  select res from t_res where t_res.k = res.k $$;

-- Fixtures: 1 customer, 2 staff, 3 admin, an order delivery method (owner insert).
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6f4-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6F4 Customer"}'),
  (pg_temp.u(2), 't6f4-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F4 Staff"}'),
  (pg_temp.u(3), 't6f4-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F4 Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');
insert into public.delivery_methods (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6f4_m', 'T6F4 method', 10000, null, 0, true, true, true);

create temp table t_pre as
  select (select count(*) from public.admin_audit_log) as audit_n;

-- =============================================================================
-- A. The admin functions still work (they run as the owner, not as authenticated)
-- =============================================================================
select pg_temp.run('a_zone', 'authenticated', pg_temp.u(3),
  $q$select public.admin_save_delivery_zone(null, 't6f4-zone', 'T6F4 Zone', 'T6F4-County', array['T6F4-Town'], null, 900)::text$q$);
select pg_temp.run('a_fee', 'authenticated', pg_temp.u(3), format(
  $q$select public.admin_save_delivery_zone_fee(null, %L::uuid, 't6f4_m', 20000, 500000, 0)::text$q$,
  (pg_temp.res('a_zone')::jsonb -> 'zone' ->> 'id')));
select pg_temp.run('a_tpl', 'authenticated', pg_temp.u(3),
  $q$select public.admin_save_delivery_slot_template(null, 'T6F4 Slot', '21:00', '21:30', null, 3, 900)::text$q$);
select pg_temp.run('a_ovr', 'authenticated', pg_temp.u(3), format(
  $q$select public.admin_save_delivery_slot_override(%L::uuid, %L::date, 2, false, 'T6F4')::text$q$,
  (pg_temp.res('a_tpl')::jsonb -> 'template' ->> 'id'), pg_temp.d(3)));
select pg_temp.run('a_method', 'authenticated', pg_temp.u(3),
  $q$select public.admin_update_delivery_method('t6f4_m', 12000, null, 0, true, null)::text$q$);
select pg_temp.run('a_zone_off', 'authenticated', pg_temp.u(3), format(
  $q$select public.admin_set_delivery_zone_active(%L::uuid, false, 'T6F4 off')::text$q$,
  (pg_temp.res('a_zone')::jsonb -> 'zone' ->> 'id')));
select pg_temp.run('a_ovr_clear', 'authenticated', pg_temp.u(3), format(
  $q$select public.admin_clear_delivery_slot_override(%L::uuid, %L::date, 'T6F4 clear')::text$q$,
  (pg_temp.res('a_tpl')::jsonb -> 'template' ->> 'id'), pg_temp.d(3)));
select pg_temp.run('a_list_cfg', 'authenticated', pg_temp.u(3), $q$select public.admin_list_delivery_config()::text$q$);
select pg_temp.run('a_list_slots', 'authenticated', pg_temp.u(3), format(
  $q$select public.admin_list_delivery_slots(%L::date, %L::date)::text$q$, pg_temp.d(0), pg_temp.d(7)));

-- =============================================================================
-- B. Direct writes by authenticated (customer, staff, admin) and anon now FAIL on every table.
--    SQLSTATE 42501 = permission denied for table (no privilege at all, not just "0 rows").
-- =============================================================================
do $b$
declare
  r record;
  w record;
  v_zone uuid := (select (pg_temp.res('a_zone')::jsonb -> 'zone' ->> 'id')::uuid from (select 1) x);
  v_fee uuid := (select (pg_temp.res('a_fee')::jsonb -> 'zone_fee' ->> 'id')::uuid from (select 1) x);
  v_tpl uuid := (select (pg_temp.res('a_tpl')::jsonb -> 'template' ->> 'id')::uuid from (select 1) x);
begin
  for r in select * from (values
      ('c', 'authenticated', pg_temp.u(1)),
      ('s', 'authenticated', pg_temp.u(2)),
      ('a', 'authenticated', pg_temp.u(3)),
      ('n', 'anon', null::uuid)) as v(tag, role, uid)
  loop
    for w in select * from (values
        ('m_ins',  $q$insert into public.delivery_methods (code, label) values ('t6f4_x', 'x')$q$),
        ('m_upd',  $q$update public.delivery_methods set base_fee_cents = 0 where code = 't6f4_m'$q$),
        ('m_del',  $q$delete from public.delivery_methods where code = 't6f4_m'$q$),
        ('z_ins',  $q$insert into public.delivery_zones (code, name) values ('t6f4-x', 'x')$q$),
        ('z_upd',  format($q$update public.delivery_zones set is_active = true where id = %L$q$, v_zone)),
        ('z_del',  format($q$delete from public.delivery_zones where id = %L$q$, v_zone)),
        ('f_ins',  format($q$insert into public.delivery_zone_fees (zone_id, method_code, fee_cents) values (%L, 't6f4_m', 0)$q$, v_zone)),
        ('f_upd',  format($q$update public.delivery_zone_fees set fee_cents = 0 where id = %L$q$, v_fee)),
        ('f_del',  format($q$delete from public.delivery_zone_fees where id = %L$q$, v_fee)),
        ('t_ins',  $q$insert into public.delivery_slot_templates (label, start_time, end_time) values ('x', '05:00', '06:00')$q$),
        ('t_upd',  format($q$update public.delivery_slot_templates set capacity = 999 where id = %L$q$, v_tpl)),
        ('t_del',  format($q$delete from public.delivery_slot_templates where id = %L$q$, v_tpl)),
        ('o_ins',  format($q$insert into public.delivery_slot_overrides (template_id, slot_date, capacity) values (%L, %L, 999)$q$, v_tpl, pg_temp.d(5))),
        ('o_upd',  $q$update public.delivery_slot_overrides set capacity = 999$q$),
        ('o_del',  $q$delete from public.delivery_slot_overrides$q$),
        ('m_trn',  $q$truncate public.delivery_zone_fees$q$),
        ('o_trn',  $q$truncate public.delivery_slot_overrides$q$)
      ) as v(op, sql)
    loop
      perform pg_temp.run('w_' || r.tag || '_' || w.op, r.role, r.uid, w.sql);
      perform pg_temp.ok(pg_temp.state('w_' || r.tag || '_' || w.op) = '42501',
        'direct write refused (42501) for ' || r.tag || ' / ' || w.op);
    end loop;
  end loop;
end
$b$;

-- Nothing the denied statements tried actually changed (read as owner).
select pg_temp.ok(
  (select base_fee_cents from public.delivery_methods where code = 't6f4_m') = 12000
  and (select count(*) from public.delivery_zones where code in ('t6f4-x')) = 0
  and (select count(*) from public.delivery_zone_fees f join public.delivery_zones z on z.id = f.zone_id where z.code = 't6f4-zone') = 1
  and (select capacity from public.delivery_slot_templates where label = 'T6F4 Slot') = 3,
  'no direct write changed any row');

-- =============================================================================
-- C. Privileges and policies on the catalog
-- =============================================================================
do $c$
declare
  v_t text;
  v_role text;
begin
  foreach v_t in array array['delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                             'delivery_slot_templates', 'delivery_slot_overrides'] loop
    foreach v_role in array array['anon', 'authenticated'] loop
      perform pg_temp.ok(
        not has_table_privilege(v_role, 'public.' || v_t, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
        and not has_any_column_privilege(v_role, 'public.' || v_t, 'INSERT, UPDATE'),
        v_role || ' holds no write privilege on ' || v_t);
    end loop;
    perform pg_temp.ok(
      not exists (select 1 from pg_policies where schemaname = 'public' and tablename = v_t
                  and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
      'no write policy on ' || v_t);
    perform pg_temp.ok((select relrowsecurity from pg_class where oid = ('public.' || v_t)::regclass),
      'RLS still enabled on ' || v_t);
    perform pg_temp.ok(has_table_privilege('service_role', 'public.' || v_t, 'SELECT, INSERT, UPDATE'),
      'service_role keeps its access to ' || v_t);
  end loop;
  perform pg_temp.ok(has_table_privilege('authenticated', 'public.delivery_methods', 'SELECT')
    and has_table_privilege('authenticated', 'public.delivery_zones', 'SELECT')
    and has_table_privilege('authenticated', 'public.delivery_zone_fees', 'SELECT')
    and has_table_privilege('anon', 'public.delivery_methods', 'SELECT')
    and has_table_privilege('anon', 'public.delivery_zones', 'SELECT')
    and has_table_privilege('anon', 'public.delivery_zone_fees', 'SELECT'),
    'customers and visitors keep SELECT on methods, zones and zone fees');
  perform pg_temp.ok(
    exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'delivery_zones' and cmd = 'SELECT')
    and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'delivery_methods' and cmd = 'SELECT'),
    'SELECT policies on zones and methods are still in place');
end
$c$;

-- =============================================================================
-- D. Customer-side reads and functions still work
-- =============================================================================
-- Re-activate the zone as the owner so the customer-facing checks have an active zone + fee rule.
update public.delivery_zones set is_active = true where code = 't6f4-zone';
update public.delivery_zone_fees set is_active = true where zone_id = (select id from public.delivery_zones where code = 't6f4-zone');

select pg_temp.run('r_zone_c', 'authenticated', pg_temp.u(1),
  $q$select count(*)::text from public.delivery_zones where code = 't6f4-zone'$q$);
select pg_temp.run('r_zone_a', 'anon', null,
  $q$select count(*)::text from public.delivery_zones where code = 't6f4-zone'$q$);
select pg_temp.run('r_method_a', 'anon', null,
  $q$select count(*)::text from public.delivery_methods where code = 't6f4_m'$q$);
select pg_temp.run('r_fee_c', 'authenticated', pg_temp.u(1),
  $q$select count(*)::text from public.delivery_zone_fees f join public.delivery_zones z on z.id = f.zone_id where z.code = 't6f4-zone'$q$);
select pg_temp.run('r_inactive_c', 'authenticated', pg_temp.u(1),
  $q$select count(*)::text from public.delivery_zones where code = 't6f4-nope'$q$);
select pg_temp.ok(pg_temp.res('r_zone_c') = '1' and pg_temp.res('r_zone_a') = '1'
                  and pg_temp.res('r_method_a') = '1' and pg_temp.res('r_fee_c') = '1',
  'customer and visitor still read active methods, zones and fee rules');

-- staff still read INACTIVE configuration (the staff read policies are untouched)
update public.delivery_zones set is_active = false where code = 't6f4-zone';
select pg_temp.run('r_staff_inactive', 'authenticated', pg_temp.u(2),
  $q$select count(*)::text from public.delivery_zones where code = 't6f4-zone'$q$);
select pg_temp.run('r_cust_inactive', 'authenticated', pg_temp.u(1),
  $q$select count(*)::text from public.delivery_zones where code = 't6f4-zone'$q$);
select pg_temp.ok(pg_temp.res('r_staff_inactive') = '1' and pg_temp.res('r_cust_inactive') = '0',
  'staff still read inactive zones; customers still do not');
update public.delivery_zones set is_active = true where code = 't6f4-zone';

-- validate_delivery_selection / resolve_delivery_fee / slots, as a customer and as a visitor
select pg_temp.run('v_sel', 'authenticated', pg_temp.u(1), format(
  $q$select row_to_json(v)::text from public.validate_delivery_selection('t6f4_m', %L::uuid, 100000) v$q$,
  (select id from public.delivery_zones where code = 't6f4-zone')));
select pg_temp.ok((pg_temp.res('v_sel')::jsonb ->> 'is_valid')::boolean is true
                  and (pg_temp.res('v_sel')::jsonb ->> 'fee_cents')::integer = 20000,
  'validate_delivery_selection works after the lockdown and uses the zone fee rule (20000 cents)');
select pg_temp.run('v_fee', 'anon', null, format(
  $q$select row_to_json(v)::text from public.resolve_delivery_fee('t6f4_m', %L::uuid, 100000) v$q$,
  (select id from public.delivery_zones where code = 't6f4-zone')));
select pg_temp.ok((pg_temp.res('v_fee')::jsonb ->> 'fee_cents')::integer = 20000,
  'resolve_delivery_fee works for a visitor');
select pg_temp.run('v_slot', 'anon', null, format(
  $q$select row_to_json(v)::text from public.validate_delivery_slot(%L::date, '21:00'::time, '21:30'::time) v$q$, pg_temp.d(3)));
select pg_temp.ok((pg_temp.res('v_slot')::jsonb ->> 'is_valid')::boolean is true,
  'validate_delivery_slot works for a visitor');
select pg_temp.run('v_avail', 'authenticated', pg_temp.u(1), format(
  $q$select count(*)::text from public.get_delivery_slot_availability(%L::date, %L::date) a join public.delivery_slot_templates t on t.id = a.template_id where t.label = 'T6F4 Slot'$q$,
  pg_temp.d(3), pg_temp.d(3)));
select pg_temp.ok(pg_temp.res('v_avail')::integer = 1,
  'get_delivery_slot_availability works for a customer');

-- create_order() does not depend on browser table privileges: it is SECURITY DEFINER and
-- executable by authenticated (its full behaviour is covered by create_order_delivery.test.sql,
-- which must be re-run after this migration).
select pg_temp.ok(
  (select bool_and(p.prosecdef) from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'create_order')
  and has_function_privilege('authenticated',
        (select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'create_order' limit 1),
        'EXECUTE'),
  'create_order is SECURITY DEFINER and still executable by authenticated');

-- =============================================================================
-- E. Gate still holds: customer / staff / anon cannot call the admin functions
-- =============================================================================
select pg_temp.run('g_c', 'authenticated', pg_temp.u(1), $q$select public.admin_list_delivery_config()::text$q$);
select pg_temp.run('g_s', 'authenticated', pg_temp.u(2), $q$select public.admin_list_delivery_config()::text$q$);
select pg_temp.run('g_a', 'anon', null, $q$select public.admin_list_delivery_config()::text$q$);
select pg_temp.ok(pg_temp.state('g_c') = '42501' and pg_temp.state('g_s') = '42501' and pg_temp.state('g_a') = '42501',
  'customer, staff and anon are still refused by the admin functions');

-- =============================================================================
-- F. Every real admin change above wrote an audit row
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.admin_audit_log) - (select audit_n from t_pre) >= 7
  and exists (select 1 from public.admin_audit_log where actor_id = pg_temp.u(3) and action = 'delivery_zone_created')
  and exists (select 1 from public.admin_audit_log where actor_id = pg_temp.u(3) and action = 'delivery_zone_fee_created')
  and exists (select 1 from public.admin_audit_log where actor_id = pg_temp.u(3) and action = 'delivery_slot_template_created')
  and exists (select 1 from public.admin_audit_log where actor_id = pg_temp.u(3) and action = 'delivery_slot_override_cleared'),
  'admin changes still write audit rows');

do $done$ begin raise notice 'ALL PHASE 6F.4 DELIVERY LOCKDOWN TESTS PASSED'; end $done$;

rollback;
