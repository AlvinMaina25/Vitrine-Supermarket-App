-- Phase 6F.1A test: delivery admin functions (methods, zones, zone fees). NOT RUN.
-- Needs migrations up to 20261005010000 applied (incl. 20261004170000 for the admin-only audit read).
-- Needs the seeded delivery methods 'standard', 'express' and 'pickup' (migration 20260930010000).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6F' (zone codes t6f-a / t6f-b). Existing zones/fees/audit rows are
-- never assumed absent: every count is a delta against a baseline taken first.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

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
  insert into t_res values (k, v_res, v_err, v_state, v_detail);
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f1a0000' || lpad(n::text, 4, '0'))::uuid $$;

create or replace function pg_temp.zid(k text) returns uuid language sql as $$
  select (res::jsonb -> 'zone' ->> 'id')::uuid from t_res where t_res.k = zid.k $$;

create or replace function pg_temp.fid(k text) returns uuid language sql as $$
  select (res::jsonb -> 'zone_fee' ->> 'id')::uuid from t_res where t_res.k = fid.k $$;

-- zone save: k, role, caller, zone id, code, name, county, towns, description, position
create or replace function pg_temp.zs(k text, r text, uid uuid, zid uuid, code text, nm text, county text,
                                      towns text[], descr text, pos integer) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_save_delivery_zone(%L::uuid, %L, %L, %L, %L::text[], %L, %L::integer)::text',
    zid, code, nm, county, towns, descr, pos));
end $$;

-- zone active: k, role, caller, zone id, active, reason
create or replace function pg_temp.za(k text, r text, uid uuid, zid uuid, active boolean, reason text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_set_delivery_zone_active(%L::uuid, %L::boolean, %L)::text', zid, active, reason));
end $$;

-- zone fee save (money passed as text so '12.5' can be tried): k, role, caller, fee id, zone id, method, fee, free_over, min
create or replace function pg_temp.fs(k text, r text, uid uuid, fid uuid, zid uuid, method text,
                                      fee text, free_over text, min_order text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_save_delivery_zone_fee(%L::uuid, %L::uuid, %L, %L::numeric, %L::numeric, %L::numeric)::text',
    fid, zid, method, fee, free_over, min_order));
end $$;

-- zone fee active: k, role, caller, fee id, active, reason
create or replace function pg_temp.fa(k text, r text, uid uuid, fid uuid, active boolean, reason text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_set_delivery_zone_fee_active(%L::uuid, %L::boolean, %L)::text', fid, active, reason));
end $$;

-- method update with explicit values: k, role, caller, code, fee, free_over, min, active, reason
create or replace function pg_temp.mu(k text, r text, uid uuid, code text, fee text, free_over text,
                                      min_order text, active boolean, reason text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_update_delivery_method(%L, %L::numeric, %L::numeric, %L::numeric, %L::boolean, %L)::text',
    code, fee, free_over, min_order, active, reason));
end $$;

-- method update keeping the CURRENT money values (only the active flag / reason is under test)
create or replace function pg_temp.mc(k text, r text, uid uuid, code text, active boolean, reason text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_update_delivery_method(m.code, m.base_fee_cents, m.free_over_cents, m.min_order_cents, %L::boolean, %L)::text from public.delivery_methods m where m.code = %L',
    active, reason, code));
end $$;

-- checkout validation as a customer: k, method, zone, subtotal
create or replace function pg_temp.cv(k text, method text, zone uuid, subtotal integer)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'authenticated', pg_temp.u(1), format(
    'select row_to_json(v)::text from public.validate_delivery_selection(%L, %L::uuid, %s) v',
    method, zone, subtotal));
end $$;

-- Fixtures: 1 customer, 2 staff, 3 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6f-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6F Customer"}'),
  (pg_temp.u(2), 't6f-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F Staff"}'),
  (pg_temp.u(3), 't6f-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

-- Baselines
create temp table t_pre as
  select (select count(*) from public.admin_audit_log) as audit_n,
         (select count(*) from public.delivery_zones) as zones_n,
         (select count(*) from public.delivery_zone_fees) as fees_n;
create temp table t_methods_before as select * from public.delivery_methods;

do $pre$
begin
  if (select count(*) from public.delivery_methods where code in ('standard', 'express', 'pickup')) <> 3
     or not (select is_active from public.delivery_methods where code = 'express')
     or not (select is_active from public.delivery_methods where code = 'standard') then
    raise exception 'PRECONDITION: seeded active methods standard/express and method pickup are required.';
  end if;
end
$pre$;

-- =============================================================================
-- A. Admin creates the fixtures (also proves "admin allowed")
-- =============================================================================
select pg_temp.zs('z1', 'authenticated', pg_temp.u(3), null, 't6f-a', '  T6F Zone A  ', 'Nairobi',
                  array['Westlands', '  Kilimani ', 'westlands', '']::text[], 'Test zone A', 5);
select pg_temp.zs('z2', 'authenticated', pg_temp.u(3), null, 't6f-b', 'T6F Zone B', '   ', null, '  ', null);
select pg_temp.fs('f1', 'authenticated', pg_temp.u(3), null, pg_temp.zid('z1'), 'standard', '30000', '600000', '100000');
select pg_temp.run('list_before', 'authenticated', pg_temp.u(3), 'select public.admin_list_delivery_config()::text');

-- =============================================================================
-- B. Denied: customer (c), staff (s), anon (a) on every function. Valid-looking arguments,
--    so the only thing stopping them is the gate.
-- =============================================================================
do $d$
declare r record;
begin
  for r in select * from (values
      ('c', 'authenticated', pg_temp.u(1)),
      ('s', 'authenticated', pg_temp.u(2)),
      ('a', 'anon', null::uuid)) as v(tag, role, uid)
  loop
    perform pg_temp.run('d_list_' || r.tag, r.role, r.uid, 'select public.admin_list_delivery_config()::text');
    perform pg_temp.zs('d_zs_' || r.tag, r.role, r.uid, pg_temp.zid('z1'), 't6f-a', 'HACKED', null, null, null, 1);
    perform pg_temp.zs('d_zc_' || r.tag, r.role, r.uid, null, 't6f-hack', 'HACKED', null, null, null, 1);
    perform pg_temp.za('d_za_' || r.tag, r.role, r.uid, pg_temp.zid('z1'), false, 'hack');
    perform pg_temp.fs('d_fs_' || r.tag, r.role, r.uid, pg_temp.fid('f1'), null, null, '1', null, '0');
    perform pg_temp.fa('d_fa_' || r.tag, r.role, r.uid, pg_temp.fid('f1'), false, 'hack');
    perform pg_temp.mu('d_mu_' || r.tag, r.role, r.uid, 'standard', '1', null, '0', true, null);
  end loop;
end
$d$;

-- =============================================================================
-- C. Zone validation
-- =============================================================================
select pg_temp.zs('zv_dup',       'authenticated', pg_temp.u(3), null, 't6f-a', 'Dup', null, null, null, null);
select pg_temp.zs('zv_nocode',    'authenticated', pg_temp.u(3), null, null, 'No code', null, null, null, null);
select pg_temp.zs('zv_badcode',   'authenticated', pg_temp.u(3), null, 'Bad Code', 'Bad', null, null, null, null);
select pg_temp.zs('zv_shortcode', 'authenticated', pg_temp.u(3), null, 'a', 'Short', null, null, null, null);
select pg_temp.zs('zv_noname',    'authenticated', pg_temp.u(3), null, 't6f-x', '   ', null, null, null, null);
select pg_temp.zs('zv_nullname',  'authenticated', pg_temp.u(3), null, 't6f-x', null, null, null, null, null);
select pg_temp.zs('zv_longname',  'authenticated', pg_temp.u(3), null, 't6f-x', repeat('n', 121), null, null, null, null);
select pg_temp.zs('zv_longcounty','authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', repeat('c', 81), null, null, null);
select pg_temp.zs('zv_longdesc',  'authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', null, null, repeat('d', 501), null);
select pg_temp.zs('zv_negpos',    'authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', null, null, null, -1);
select pg_temp.zs('zv_bigpos',    'authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', null, null, null, 1000001);
select pg_temp.zs('zv_manytowns', 'authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', null,
                  (select array_agg('town' || i) from generate_series(1, 101) i), null, null);
select pg_temp.zs('zv_longtown',  'authenticated', pg_temp.u(3), null, 't6f-x', 'Ok', null, array[repeat('t', 81)]::text[], null, null);
select pg_temp.zs('zv_u_noname',  'authenticated', pg_temp.u(3), pg_temp.zid('z1'), null, '  ', null, null, null, null);
select pg_temp.zs('zv_u_code',    'authenticated', pg_temp.u(3), pg_temp.zid('z1'), 't6f-zzz', 'Zone A', null, null, null, null);
select pg_temp.zs('zv_u_missing', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1a0000ffff', null, 'X', null, null, null, null);
-- unchanged save: same values as created -> changed=false
select pg_temp.zs('zu_same',      'authenticated', pg_temp.u(3), pg_temp.zid('z1'), 't6f-a', 'T6F Zone A', 'Nairobi',
                  array['Westlands', 'Kilimani']::text[], 'Test zone A', 5);

-- zone active validation (z1 is active now)
select pg_temp.za('za_noreason',  'authenticated', pg_temp.u(3), pg_temp.zid('z1'), false, null);
select pg_temp.za('za_blank',     'authenticated', pg_temp.u(3), pg_temp.zid('z1'), false, '   ');
select pg_temp.za('za_long',      'authenticated', pg_temp.u(3), pg_temp.zid('z1'), false, repeat('r', 501));
select pg_temp.za('za_nullactive','authenticated', pg_temp.u(3), pg_temp.zid('z1'), null, 'why');
select pg_temp.za('za_nullid',    'authenticated', pg_temp.u(3), null, false, 'why');
select pg_temp.za('za_unknown',   'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1a0000ffff', false, 'why');
select pg_temp.za('za_same',      'authenticated', pg_temp.u(3), pg_temp.zid('z1'), true, 'already active');

-- =============================================================================
-- D. Zone fee validation (z2 has no rule yet, so rejections are about the values, not duplicates)
-- =============================================================================
select pg_temp.fs('fv_negfee',   'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '-1', null, '0');
select pg_temp.fs('fv_fracfee',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '12.5', null, '0');
select pg_temp.fs('fv_nullfee',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', null, null, '0');
select pg_temp.fs('fv_hugefee',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '2147483648', null, '0');
select pg_temp.fs('fv_negfree',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '100', '-1', '0');
select pg_temp.fs('fv_fracfree', 'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '100', '1.5', '0');
select pg_temp.fs('fv_negmin',   'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '100', null, '-5');
select pg_temp.fs('fv_fracmin',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'standard', '100', null, '0.5');
select pg_temp.fs('fv_nozone',   'authenticated', pg_temp.u(3), null, null, 'standard', '100', null, '0');
select pg_temp.fs('fv_nomethod', 'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), null, '100', null, '0');
select pg_temp.fs('fv_blankmeth','authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), '  ', '100', null, '0');
select pg_temp.fs('fv_unkzone',  'authenticated', pg_temp.u(3), null, '00000000-0000-4000-8000-6f1a0000ffff', 'standard', '100', null, '0');
select pg_temp.fs('fv_unkmeth',  'authenticated', pg_temp.u(3), null, pg_temp.zid('z2'), 'nope', '100', null, '0');
select pg_temp.fs('fv_dup',      'authenticated', pg_temp.u(3), null, pg_temp.zid('z1'), 'standard', '100', null, '0');
select pg_temp.fs('fv_u_missing','authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1a0000ffff', null, null, '100', null, '0');
select pg_temp.fs('fv_u_negfee', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), null, null, '-1', null, '0');
select pg_temp.fs('fv_u_zone',   'authenticated', pg_temp.u(3), pg_temp.fid('f1'), pg_temp.zid('z2'), null, '100', null, '0');
select pg_temp.fs('fv_u_method', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), null, 'pickup', '100', null, '0');
select pg_temp.fs('fu_same',     'authenticated', pg_temp.u(3), pg_temp.fid('f1'), pg_temp.zid('z1'), 'standard', '30000', '600000', '100000');

-- fee active validation (f1 is active now)
select pg_temp.fa('fa_noreason', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), false, null);
select pg_temp.fa('fa_blank',    'authenticated', pg_temp.u(3), pg_temp.fid('f1'), false, '  ');
select pg_temp.fa('fa_long',     'authenticated', pg_temp.u(3), pg_temp.fid('f1'), false, repeat('r', 501));
select pg_temp.fa('fa_nullact',  'authenticated', pg_temp.u(3), pg_temp.fid('f1'), null, 'why');
select pg_temp.fa('fa_nullid',   'authenticated', pg_temp.u(3), null, false, 'why');
select pg_temp.fa('fa_unknown',  'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1a0000ffff', false, 'why');
select pg_temp.fa('fa_same',     'authenticated', pg_temp.u(3), pg_temp.fid('f1'), true, 'already active');

-- =============================================================================
-- E. Method validation (standard must be unchanged by every rejected call)
-- =============================================================================
create temp table t_std_before as select * from public.delivery_methods where code = 'standard';
select pg_temp.mu('mv_negfee',   'authenticated', pg_temp.u(3), 'standard', '-1', null, '0', true, null);
select pg_temp.mu('mv_fracfee',  'authenticated', pg_temp.u(3), 'standard', '12.5', null, '0', true, null);
select pg_temp.mu('mv_nullfee',  'authenticated', pg_temp.u(3), 'standard', null, null, '0', true, null);
select pg_temp.mu('mv_hugefee',  'authenticated', pg_temp.u(3), 'standard', '2147483648', null, '0', true, null);
select pg_temp.mu('mv_negfree',  'authenticated', pg_temp.u(3), 'standard', '100', '-1', '0', true, null);
select pg_temp.mu('mv_fracfree', 'authenticated', pg_temp.u(3), 'standard', '100', '1.5', '0', true, null);
select pg_temp.mu('mv_negmin',   'authenticated', pg_temp.u(3), 'standard', '100', null, '-5', true, null);
select pg_temp.mu('mv_nullmin',  'authenticated', pg_temp.u(3), 'standard', '100', null, null, true, null);
select pg_temp.mu('mv_fracmin',  'authenticated', pg_temp.u(3), 'standard', '100', null, '0.5', true, null);
select pg_temp.mu('mv_nullact',  'authenticated', pg_temp.u(3), 'standard', '100', null, '0', null, null);
select pg_temp.mu('mv_nocode',   'authenticated', pg_temp.u(3), null, '100', null, '0', true, null);
select pg_temp.mu('mv_unknown',  'authenticated', pg_temp.u(3), 'nope', '100', null, '0', true, null);
select pg_temp.mu('mv_longreason','authenticated', pg_temp.u(3), 'standard', '100', null, '0', true, repeat('r', 501));
select pg_temp.mc('mv_actnoreason','authenticated', pg_temp.u(3), 'express', false, null);
select pg_temp.mc('mv_actblank',  'authenticated', pg_temp.u(3), 'express', false, '  ');

-- =============================================================================
-- F. Successful changes interleaved with checkout checks (customer role)
-- =============================================================================
select pg_temp.cv('cv1_before', 'standard', pg_temp.zid('z1'), 150000);

select pg_temp.za('za_off',       'authenticated', pg_temp.u(3), pg_temp.zid('z1'), false, '  Paused for review  ');
select pg_temp.za('za_off_again', 'authenticated', pg_temp.u(3), pg_temp.zid('z1'), false, 'twice');
select pg_temp.run('list_inactive', 'authenticated', pg_temp.u(3), 'select public.admin_list_delivery_config()::text');
select pg_temp.run('cust_sees_off', 'authenticated', pg_temp.u(1),
  format('select count(*)::text from public.delivery_zones where id = %L', pg_temp.zid('z1')));
select pg_temp.cv('cv2_zone_off',  'standard', pg_temp.zid('z1'), 150000);
select pg_temp.cv('cv3_other_zone','standard', pg_temp.zid('z2'), 150000);
select pg_temp.cv('cv4_pickup',    'pickup',   null,              150000);

select pg_temp.za('za_on', 'authenticated', pg_temp.u(3), pg_temp.zid('z1'), true, 'Back in service');
select pg_temp.run('cust_sees_on', 'authenticated', pg_temp.u(1),
  format('select count(*)::text from public.delivery_zones where id = %L', pg_temp.zid('z1')));
select pg_temp.cv('cv5_zone_on', 'standard', pg_temp.zid('z1'), 150000);

select pg_temp.fa('fa_off', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), false, 'Rule under review');
select pg_temp.fa('fa_off_again', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), false, 'twice');
select pg_temp.cv('cv6_rule_off', 'standard', pg_temp.zid('z1'), 150000);
select pg_temp.fa('fa_on', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), true, 'Rule confirmed');
select pg_temp.cv('cv7_rule_on', 'standard', pg_temp.zid('z1'), 150000);

-- zone update
select pg_temp.zs('zu', 'authenticated', pg_temp.u(3), pg_temp.zid('z1'), null, ' T6F Zone A2 ', 'Nairobi County',
                  array['Kilimani', 'Lavington']::text[], 'Updated', 7);
-- fee update (free_over NULL = never waived)
select pg_temp.fs('fu', 'authenticated', pg_temp.u(3), pg_temp.fid('f1'), null, null, '35000', null, null);
-- method update: current fee + 1000, threshold 550000, min 1000, stays active, no reason needed
select pg_temp.mu('mu', 'authenticated', pg_temp.u(3), 'standard',
  (select (base_fee_cents + 1000)::text from public.delivery_methods where code = 'standard'),
  '550000', '1000', true, '  price review  ');
select pg_temp.mu('mu_same', 'authenticated', pg_temp.u(3), 'standard',
  (select base_fee_cents::text from public.delivery_methods where code = 'standard'),
  '550000', '1000', true, null);
select pg_temp.mc('ex_off', 'authenticated', pg_temp.u(3), 'express', false, ' Courier unavailable ');
select pg_temp.mc('ex_on',  'authenticated', pg_temp.u(3), 'express', true, 'Courier back');
select pg_temp.run('list_final', 'authenticated', pg_temp.u(3), 'select public.admin_list_delivery_config()::text');

-- =============================================================================
-- G. Assertions
-- =============================================================================
do $t$
declare
  v_pre t_pre%rowtype;
  v_a uuid := pg_temp.u(3);
  v_zone public.delivery_zones%rowtype;
  v_fee public.delivery_zone_fees%rowtype;
  v_std public.delivery_methods%rowtype;
  v_sb public.delivery_methods%rowtype;
  v_n bigint;
  v_cfg jsonb;
  v_sig text;
  r record;
begin
  select * into v_pre from t_pre;

  -- ---- access ----
  for r in select k from t_res where k like 'd\_%' order by k loop
    if r.k like '%\_a' then
      perform pg_temp.ok(pg_temp.err(r.k) like '42501/%', 'anon denied: ' || r.k);
    else
      perform pg_temp.ok(pg_temp.err(r.k) = '42501/not_authorised',
                         'customer/staff denied with not_authorised: ' || r.k);
    end if;
  end loop;
  perform pg_temp.ok((select count(*) from t_res where k like 'd\_%') = 21, 'all 7 functions x 3 callers were attempted');
  perform pg_temp.ok(pg_temp.j('z1') ->> 'created' = 'true' and pg_temp.j('f1') ->> 'created' = 'true'
                     and pg_temp.j('list_before') is not null, 'admin is allowed (create zone, create fee, list)');

  -- denied calls changed nothing
  select * into v_zone from public.delivery_zones where id = pg_temp.zid('z1');
  select * into v_fee from public.delivery_zone_fees where id = pg_temp.fid('f1');
  perform pg_temp.ok(not exists (select 1 from public.delivery_zones where code = 't6f-hack'), 'denied create wrote no zone');

  -- ---- zone create result + normalisation ----
  perform pg_temp.ok(pg_temp.j('z1') -> 'zone' ->> 'name' = 'T6F Zone A', 'zone name trimmed');
  perform pg_temp.ok((select towns from public.delivery_zones where code = 't6f-a') is not null, 'z1 exists');
  -- z1 has since been updated; the creation result itself is what shows normalisation:
  perform pg_temp.ok((pg_temp.j('z1') -> 'zone' -> 'towns') = '["Westlands", "Kilimani"]'::jsonb,
                     'towns trimmed, blank and case-insensitive duplicate dropped, order kept');
  perform pg_temp.ok(pg_temp.j('z1') -> 'zone' ->> 'is_active' = 'true' and pg_temp.j('z1') -> 'zone' ->> 'position' = '5',
                     'new zone is active, position kept');
  perform pg_temp.ok((pg_temp.j('z2') -> 'zone' ->> 'county') is null and (pg_temp.j('z2') -> 'zone' ->> 'description') is null
                     and pg_temp.j('z2') -> 'zone' ->> 'position' = '0' and pg_temp.j('z2') -> 'zone' -> 'towns' = '[]'::jsonb,
                     'blank county/description become NULL, null position -> 0, null towns -> empty');

  -- ---- zone validation ----
  perform pg_temp.ok(pg_temp.err('zv_dup') = 'P0001/code_taken', 'duplicate zone code rejected');
  perform pg_temp.ok(pg_temp.err('zv_nocode') = 'P0001/invalid_code', 'null code rejected on create');
  perform pg_temp.ok(pg_temp.err('zv_badcode') = 'P0001/invalid_code', 'malformed code rejected');
  perform pg_temp.ok(pg_temp.err('zv_shortcode') = 'P0001/invalid_code', 'one-character code rejected');
  perform pg_temp.ok(pg_temp.err('zv_noname') = 'P0001/name_required', 'blank name rejected');
  perform pg_temp.ok(pg_temp.err('zv_nullname') = 'P0001/name_required', 'null name rejected');
  perform pg_temp.ok(pg_temp.err('zv_longname') = 'P0001/name_too_long', 'name over 120 rejected');
  perform pg_temp.ok(pg_temp.err('zv_longcounty') = 'P0001/county_too_long', 'county over 80 rejected');
  perform pg_temp.ok(pg_temp.err('zv_longdesc') = 'P0001/description_too_long', 'description over 500 rejected');
  perform pg_temp.ok(pg_temp.err('zv_negpos') = 'P0001/invalid_position', 'negative position rejected');
  perform pg_temp.ok(pg_temp.err('zv_bigpos') = 'P0001/invalid_position', 'position over 1000000 rejected');
  perform pg_temp.ok(pg_temp.err('zv_manytowns') = 'P0001/invalid_towns', '101 towns rejected');
  perform pg_temp.ok(pg_temp.err('zv_longtown') = 'P0001/invalid_towns', 'town over 80 chars rejected');
  perform pg_temp.ok(pg_temp.err('zv_u_noname') = 'P0001/name_required', 'blank name rejected on update');
  perform pg_temp.ok(pg_temp.err('zv_u_code') = 'P0001/code_immutable', 'zone code cannot change');
  perform pg_temp.ok(pg_temp.err('zv_u_missing') = 'P0001/zone_not_found', 'unknown zone rejected on update');
  perform pg_temp.ok(pg_temp.j('zu_same') ->> 'changed' = 'false', 'identical zone save reports changed=false');
  perform pg_temp.ok((select count(*) from public.delivery_zones) = v_pre.zones_n + 2,
                     'rejected zone calls created nothing (only z1 and z2 exist beyond baseline)');

  perform pg_temp.ok(pg_temp.err('za_noreason') = 'P0001/reason_required', 'zone deactivate: null reason rejected');
  perform pg_temp.ok(pg_temp.err('za_blank') = 'P0001/reason_required', 'zone deactivate: blank reason rejected');
  perform pg_temp.ok(pg_temp.err('za_long') = 'P0001/reason_too_long', 'zone deactivate: reason over 500 rejected');
  perform pg_temp.ok(pg_temp.err('za_nullactive') = 'P0001/invalid_arguments', 'zone active: null state rejected');
  perform pg_temp.ok(pg_temp.err('za_nullid') = 'P0001/invalid_arguments', 'zone active: null id rejected');
  perform pg_temp.ok(pg_temp.err('za_unknown') = 'P0001/zone_not_found', 'zone active: unknown zone rejected');
  perform pg_temp.ok(pg_temp.err('za_same') = 'P0001/status_unchanged', 'zone active: no-op rejected');
  perform pg_temp.ok(pg_temp.err('za_off_again') = 'P0001/status_unchanged', 'zone deactivate twice rejected');
  perform pg_temp.ok(pg_temp.j('za_off') ->> 'previous_is_active' = 'true' and pg_temp.j('za_off') ->> 'is_active' = 'false'
                     and pg_temp.j('za_on') ->> 'is_active' = 'true', 'zone deactivate / reactivate results');

  -- ---- zone fee validation ----
  perform pg_temp.ok(pg_temp.err('fv_negfee') = 'P0001/invalid_fee', 'negative fee rejected');
  perform pg_temp.ok(pg_temp.err('fv_fracfee') = 'P0001/invalid_fee', 'fractional fee (12.5) rejected');
  perform pg_temp.ok(pg_temp.err('fv_nullfee') = 'P0001/invalid_fee', 'null fee rejected');
  perform pg_temp.ok(pg_temp.err('fv_hugefee') = 'P0001/invalid_fee', 'fee above integer range rejected');
  perform pg_temp.ok(pg_temp.err('fv_negfree') = 'P0001/invalid_free_over', 'negative free-over rejected');
  perform pg_temp.ok(pg_temp.err('fv_fracfree') = 'P0001/invalid_free_over', 'fractional free-over rejected');
  perform pg_temp.ok(pg_temp.err('fv_negmin') = 'P0001/invalid_min_order', 'negative minimum order rejected');
  perform pg_temp.ok(pg_temp.err('fv_fracmin') = 'P0001/invalid_min_order', 'fractional minimum order rejected');
  perform pg_temp.ok(pg_temp.err('fv_nozone') = 'P0001/invalid_arguments', 'create without zone rejected');
  perform pg_temp.ok(pg_temp.err('fv_nomethod') = 'P0001/invalid_arguments', 'create without method rejected');
  perform pg_temp.ok(pg_temp.err('fv_blankmeth') = 'P0001/invalid_arguments', 'create with blank method rejected');
  perform pg_temp.ok(pg_temp.err('fv_unkzone') = 'P0001/zone_not_found', 'create for unknown zone rejected');
  perform pg_temp.ok(pg_temp.err('fv_unkmeth') = 'P0001/method_not_found', 'create for unknown method rejected');
  perform pg_temp.ok(pg_temp.err('fv_dup') = 'P0001/zone_fee_exists', 'second rule for the same zone x method rejected');
  perform pg_temp.ok(pg_temp.err('fv_u_missing') = 'P0001/zone_fee_not_found', 'unknown fee rule rejected on update');
  perform pg_temp.ok(pg_temp.err('fv_u_negfee') = 'P0001/invalid_fee', 'negative fee rejected on update');
  perform pg_temp.ok(pg_temp.err('fv_u_zone') = 'P0001/immutable_fields', 'fee rule zone cannot change');
  perform pg_temp.ok(pg_temp.err('fv_u_method') = 'P0001/immutable_fields', 'fee rule method cannot change');
  perform pg_temp.ok(pg_temp.j('fu_same') ->> 'changed' = 'false', 'identical fee save reports changed=false');
  perform pg_temp.ok((select count(*) from public.delivery_zone_fees) = v_pre.fees_n + 1,
                     'rejected fee calls created nothing (only f1 exists beyond baseline)');
  perform pg_temp.ok(pg_temp.err('fa_noreason') = 'P0001/reason_required', 'fee deactivate: null reason rejected');
  perform pg_temp.ok(pg_temp.err('fa_blank') = 'P0001/reason_required', 'fee deactivate: blank reason rejected');
  perform pg_temp.ok(pg_temp.err('fa_long') = 'P0001/reason_too_long', 'fee deactivate: reason over 500 rejected');
  perform pg_temp.ok(pg_temp.err('fa_nullact') = 'P0001/invalid_arguments', 'fee active: null state rejected');
  perform pg_temp.ok(pg_temp.err('fa_nullid') = 'P0001/invalid_arguments', 'fee active: null id rejected');
  perform pg_temp.ok(pg_temp.err('fa_unknown') = 'P0001/zone_fee_not_found', 'fee active: unknown rule rejected');
  perform pg_temp.ok(pg_temp.err('fa_same') = 'P0001/status_unchanged', 'fee active: no-op rejected');
  perform pg_temp.ok(pg_temp.err('fa_off_again') = 'P0001/status_unchanged', 'fee deactivate twice rejected');

  -- ---- method validation ----
  perform pg_temp.ok(pg_temp.err('mv_negfee') = 'P0001/invalid_fee', 'method: negative fee rejected');
  perform pg_temp.ok(pg_temp.err('mv_fracfee') = 'P0001/invalid_fee', 'method: fractional fee rejected');
  perform pg_temp.ok(pg_temp.err('mv_nullfee') = 'P0001/invalid_fee', 'method: null fee rejected');
  perform pg_temp.ok(pg_temp.err('mv_hugefee') = 'P0001/invalid_fee', 'method: fee above integer range rejected');
  perform pg_temp.ok(pg_temp.err('mv_negfree') = 'P0001/invalid_free_over', 'method: negative free-over rejected');
  perform pg_temp.ok(pg_temp.err('mv_fracfree') = 'P0001/invalid_free_over', 'method: fractional free-over rejected');
  perform pg_temp.ok(pg_temp.err('mv_negmin') = 'P0001/invalid_min_order', 'method: negative minimum order rejected');
  perform pg_temp.ok(pg_temp.err('mv_nullmin') = 'P0001/invalid_min_order', 'method: null minimum order rejected');
  perform pg_temp.ok(pg_temp.err('mv_fracmin') = 'P0001/invalid_min_order', 'method: fractional minimum order rejected');
  perform pg_temp.ok(pg_temp.err('mv_nullact') = 'P0001/invalid_arguments', 'method: null active rejected');
  perform pg_temp.ok(pg_temp.err('mv_nocode') = 'P0001/invalid_arguments', 'method: null code rejected');
  perform pg_temp.ok(pg_temp.err('mv_unknown') = 'P0001/method_not_found', 'method: unknown code rejected');
  perform pg_temp.ok(pg_temp.err('mv_longreason') = 'P0001/reason_too_long', 'method: reason over 500 rejected');
  perform pg_temp.ok(pg_temp.err('mv_actnoreason') = 'P0001/reason_required', 'method: deactivate without reason rejected');
  perform pg_temp.ok(pg_temp.err('mv_actblank') = 'P0001/reason_required', 'method: deactivate with blank reason rejected');

  -- ---- method result: only the four fields change ----
  select * into v_std from public.delivery_methods where code = 'standard';
  select * into v_sb from t_std_before;
  perform pg_temp.ok(v_std.base_fee_cents = v_sb.base_fee_cents + 1000 and v_std.free_over_cents = 550000
                     and v_std.min_order_cents = 1000 and v_std.is_active, 'method money fields updated as integer cents');
  perform pg_temp.ok(v_std.label = v_sb.label and v_std.description is not distinct from v_sb.description
                     and v_std.requires_slot = v_sb.requires_slot and v_std.requires_address = v_sb.requires_address
                     and v_std.eta_label is not distinct from v_sb.eta_label and v_std.position = v_sb.position
                     and v_std.created_at = v_sb.created_at, 'other method columns untouched');
  perform pg_temp.ok(pg_temp.j('mu') ->> 'changed' = 'true' and pg_temp.j('mu_same') ->> 'changed' = 'false',
                     'method update reports changed true, then false when repeated');
  perform pg_temp.ok(pg_temp.j('ex_off') -> 'method' ->> 'is_active' = 'false'
                     and pg_temp.j('ex_on') -> 'method' ->> 'is_active' = 'true'
                     and (select is_active from public.delivery_methods where code = 'express'), 'method deactivate / reactivate with reason');
  perform pg_temp.ok((select base_fee_cents from public.delivery_methods where code = 'express')
                     = (select base_fee_cents from t_methods_before where code = 'express'),
                     'active toggle left the express money fields as they were');

  -- ---- successful zone / fee updates ----
  select * into v_zone from public.delivery_zones where id = pg_temp.zid('z1');
  perform pg_temp.ok(v_zone.name = 'T6F Zone A2' and v_zone.county = 'Nairobi County' and v_zone.towns = array['Kilimani', 'Lavington']
                     and v_zone.description = 'Updated' and v_zone.position = 7 and v_zone.code = 't6f-a' and v_zone.is_active,
                     'zone update applied, code and active unchanged');
  select * into v_fee from public.delivery_zone_fees where id = pg_temp.fid('f1');
  perform pg_temp.ok(v_fee.fee_cents = 35000 and v_fee.free_over_cents is null and v_fee.min_order_cents = 0 and v_fee.is_active
                     and v_fee.zone_id = pg_temp.zid('z1') and v_fee.method_code = 'standard',
                     'fee update applied (free-over NULL = never, min NULL -> 0); zone and method unchanged');

  -- ---- checkout still works after a zone is deactivated ----
  perform pg_temp.ok(pg_temp.j('cv1_before') ->> 'is_valid' = 'true' and pg_temp.j('cv1_before') ->> 'fee_source' = 'zone'
                     and pg_temp.j('cv1_before') ->> 'fee_cents' = '30000', 'before: active zone + rule -> valid, zone fee 30000');
  perform pg_temp.ok(pg_temp.j('cv2_zone_off') ->> 'is_valid' = 'false' and pg_temp.j('cv2_zone_off') ->> 'error_code' = 'zone_inactive',
                     'deactivated zone -> validate_delivery_selection rejects it cleanly (zone_inactive), no exception');
  perform pg_temp.ok(pg_temp.j('cv3_other_zone') ->> 'is_valid' = 'true' and pg_temp.j('cv3_other_zone') ->> 'fee_source' = 'method'
                     and pg_temp.j('cv3_other_zone') ->> 'zone_id' = pg_temp.zid('z2')::text,
                     'another active zone still validates (method fee, no rule)');
  perform pg_temp.ok(pg_temp.j('cv4_pickup') ->> 'is_valid' = 'true', 'pickup (no zone) still validates');
  perform pg_temp.ok((select res from t_res where k = 'cust_sees_off') = '0', 'customers cannot see the deactivated zone');
  perform pg_temp.ok((select res from t_res where k = 'cust_sees_on') = '1', 'customers see the zone again once reactivated');
  perform pg_temp.ok(pg_temp.j('cv5_zone_on') ->> 'is_valid' = 'true' and pg_temp.j('cv5_zone_on') ->> 'fee_source' = 'zone'
                     and pg_temp.j('cv5_zone_on') ->> 'fee_cents' = '30000', 'reactivated zone validates again with its rule');
  perform pg_temp.ok(pg_temp.j('cv6_rule_off') ->> 'is_valid' = 'true' and pg_temp.j('cv6_rule_off') ->> 'fee_source' = 'method',
                     'deactivated fee rule -> zone falls back to the method fee');
  perform pg_temp.ok(pg_temp.j('cv7_rule_on') ->> 'is_valid' = 'true' and pg_temp.j('cv7_rule_on') ->> 'fee_source' = 'zone'
                     and pg_temp.j('cv7_rule_on') ->> 'fee_cents' = '30000', 'reactivated fee rule applies again');

  -- ---- list ----
  v_cfg := pg_temp.j('list_inactive');
  perform pg_temp.ok(jsonb_array_length(v_cfg -> 'methods') >= 3 and jsonb_array_length(v_cfg -> 'zones') >= 2
                     and jsonb_array_length(v_cfg -> 'zone_fees') >= 1, 'list returns methods, zones and zone fees');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(v_cfg -> 'zones') z
                             where z ->> 'code' = 't6f-a' and z ->> 'is_active' = 'false'),
                     'list includes INACTIVE zones');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(v_cfg -> 'zone_fees') f
                             where f ->> 'zone_code' = 't6f-a' and f ->> 'method_code' = 'standard'
                               and f ->> 'method_label' is not null and f ->> 'zone_name' is not null),
                     'list zone fees carry zone_code, zone_name and method_label');
  perform pg_temp.ok((select (m ->> 'position')::int from jsonb_array_elements(v_cfg -> 'methods') with ordinality x(m, o) where o = 1)
                     <= (select (m ->> 'position')::int from jsonb_array_elements(v_cfg -> 'methods') with ordinality x(m, o) where o = 2),
                     'list methods are ordered by position');
  perform pg_temp.ok(jsonb_array_length(pg_temp.j('list_final') -> 'zones') = v_pre.zones_n + 2
                     and jsonb_array_length(pg_temp.j('list_final') -> 'zone_fees') = v_pre.fees_n + 1,
                     'final list matches the table counts');

  -- ---- audit ----
  select count(*) into v_n from public.admin_audit_log;
  perform pg_temp.ok(v_n = v_pre.audit_n + 12,
                     'exactly 12 audit rows for the 12 real changes (denied, invalid and no-op calls wrote none)');
  perform pg_temp.ok((select count(*) from public.admin_audit_log where actor_id = v_a) = 12, 'all 12 rows carry the admin as actor');
  perform pg_temp.ok((select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_created') = 2
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_updated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_deactivated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_activated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_fee_created') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_fee_updated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_fee_deactivated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_zone_fee_activated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_method_updated') = 3,
                     'audit rows by action: zone 2 created/1 updated/1 off/1 on, fee 1 created/1 updated/1 off/1 on, method 3');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_zone_deactivated'
                               and target_id = pg_temp.zid('z1') and reason = 'Paused for review' and created_at is not null),
                     'zone deactivate audit row: target, trimmed reason');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_zone_fee_deactivated'
                               and target_id = pg_temp.fid('f1') and reason = 'Rule under review'),
                     'fee deactivate audit row: target, reason');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_zone_fee_updated' and target_id = pg_temp.fid('f1')
                               and reason like 't6f-a / standard:%fee_cents 30000 -> 35000%free_over_cents 600000 -> none%min_order_cents 100000 -> 0%'),
                     'fee update audit row summarises old -> new cents');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_zone_updated' and target_id = pg_temp.zid('z1')
                               and reason like 't6f-a: name: T6F Zone A -> T6F Zone A2%towns: 2 -> 2 entries%position: 5 -> 7'),
                     'zone update audit row summarises the changed fields');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_method_updated' and target_id is null
                               and reason like 'standard: base_fee_cents %free_over_cents % -> 550000; min_order_cents % -> 1000 | reason: price review'),
                     'method audit row: code first, old -> new cents, trimmed reason');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where actor_id = v_a and action = 'delivery_method_updated'
                               and reason = 'express: is_active true -> false | reason: Courier unavailable'),
                     'method deactivate audit row');

  -- ---- direct-write grants were revoked by 20261005030000 (6F.4) ----
  perform pg_temp.ok(not has_column_privilege('authenticated', 'public.delivery_zones', 'name', 'UPDATE')
                     and not has_column_privilege('authenticated', 'public.delivery_zone_fees', 'fee_cents', 'UPDATE')
                     and not has_column_privilege('authenticated', 'public.delivery_methods', 'base_fee_cents', 'UPDATE'),
                     'direct column UPDATE grants are gone (6F.4)');

  -- ---- function properties ----
  foreach v_sig in array array[
    'public.admin_list_delivery_config()',
    'public.admin_save_delivery_zone(uuid,text,text,text,text[],text,integer)',
    'public.admin_set_delivery_zone_active(uuid,boolean,text)',
    'public.admin_save_delivery_zone_fee(uuid,uuid,text,numeric,numeric,numeric)',
    'public.admin_set_delivery_zone_fee_active(uuid,boolean,text)',
    'public.admin_update_delivery_method(text,numeric,numeric,numeric,boolean,text)'] loop
    perform pg_temp.ok((select p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                        from pg_proc p where p.oid = v_sig::regprocedure)
                       and not has_function_privilege('anon', v_sig, 'EXECUTE')
                       and has_function_privilege('authenticated', v_sig, 'EXECUTE'),
                       'SECURITY DEFINER, pinned search_path, anon denied, authenticated granted: ' || v_sig);
  end loop;

  raise notice 'ALL PHASE 6F.1A DELIVERY ADMIN TESTS PASSED';
end
$t$;

rollback;
