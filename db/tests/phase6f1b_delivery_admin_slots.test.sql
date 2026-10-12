-- Phase 6F.1B test: delivery admin functions (slot templates + per-date overrides). NOT RUN on the real Supabase.
-- Needs migrations up to 20261005020000 applied.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6FB' (labels) and windows 21:00-23:45, which no seeded template uses.
-- Existing templates/overrides/audit rows are never assumed absent: counts are deltas against a
-- baseline taken first. Dates are relative to today in Africa/Nairobi (d(n) = today + n), so the
-- script works on any day.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

create or replace function pg_temp.d(n integer) returns date language sql stable as $$
  select ((now() at time zone 'Africa/Nairobi')::date + n) $$;

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

create or replace function pg_temp.msg(k text) returns text language sql as $$
  select err from t_res where t_res.k = msg.k $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f1b0000' || lpad(n::text, 4, '0'))::uuid $$;

create or replace function pg_temp.tid(k text) returns uuid language sql as $$
  select (res::jsonb -> 'template' ->> 'id')::uuid from t_res where t_res.k = tid.k $$;

-- template save: k, role, caller, id, label, start, end, weekday, capacity (text), position
create or replace function pg_temp.ts(k text, r text, uid uuid, tid uuid, label text, st text, en text,
                                      dow integer, cap text, pos integer) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_save_delivery_slot_template(%L::uuid, %L, %L::time, %L::time, %L::integer, %L::numeric, %L::integer)::text',
    tid, label, st, en, dow, cap, pos));
end $$;

-- template active: k, role, caller, id, active, reason
create or replace function pg_temp.ta(k text, r text, uid uuid, tid uuid, active boolean, reason text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_set_delivery_slot_template_active(%L::uuid, %L::boolean, %L)::text', tid, active, reason));
end $$;

-- override save: k, role, caller, template, date, capacity (text), closed, note
create or replace function pg_temp.os(k text, r text, uid uuid, tid uuid, dt date, cap text, closed boolean, note text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_save_delivery_slot_override(%L::uuid, %L::date, %L::numeric, %L::boolean, %L)::text',
    tid, dt, cap, closed, note));
end $$;

-- override clear: k, role, caller, template, date, reason
create or replace function pg_temp.oc(k text, r text, uid uuid, tid uuid, dt date, reason text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format(
    'select public.admin_clear_delivery_slot_override(%L::uuid, %L::date, %L)::text', tid, dt, reason));
end $$;

-- list: k, role, caller, from, to
create or replace function pg_temp.sl(k text, r text, uid uuid, f date, t date)
returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format('select public.admin_list_delivery_slots(%L::date, %L::date)::text', f, t));
end $$;

-- customer-facing checks, as anon: validate one window / list availability of OUR templates on a date
create or replace function pg_temp.vs(k text, dt date, st text, en text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'anon', null, format(
    'select row_to_json(v)::text from public.validate_delivery_slot(%L::date, %L::time, %L::time) v', dt, st, en));
end $$;

create or replace function pg_temp.av(k text, dt date) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'anon', null, format(
    'select coalesce(jsonb_agg(a.template_id order by a.template_id), ''[]''::jsonb)::text from public.get_delivery_slot_availability(%L::date, %L::date) a join public.delivery_slot_templates t on t.id = a.template_id where t.label like ''T6FB%%''',
    dt, dt));
end $$;

-- an order that holds (or not) a slot, inserted as owner
create or replace function pg_temp.mk(p_date date, p_start time, p_end time, p_status public.order_status default 'pending')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.orders (user_id, order_number, status, payment_method, delivery_method,
                             delivery_slot_date, delivery_slot_start, delivery_slot_end)
  values (pg_temp.u(1), 'T6FB-' || substr(gen_random_uuid()::text, 1, 12), p_status, 'cash_on_delivery', 't6fb_m',
          p_date, p_start, p_end)
  returning id into v_id;
  return v_id;
end $$;

-- Fixtures: 1 customer, 2 staff, 3 admin, an order delivery method
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6fb-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6FB Customer"}'),
  (pg_temp.u(2), 't6fb-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6FB Staff"}'),
  (pg_temp.u(3), 't6fb-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6FB Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');
insert into public.delivery_methods (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6fb_m', 'T6FB method', 0, null, 0, true, false, true);

-- Baselines
create temp table t_pre as
  select (select count(*) from public.admin_audit_log) as audit_n,
         (select count(*) from public.delivery_slot_templates) as tpl_n,
         (select count(*) from public.delivery_slot_overrides) as ovr_n;

-- =============================================================================
-- A. Admin creates the templates (also proves "admin allowed") and the bookings
--    t1 21:00-21:30 every day, cap 3   t2 21:30-22:00 only on d(4)'s weekday, cap 2
--    t3 22:00-22:30 every day, unlimited   t4 23:00-23:30 every day, cap 5
-- =============================================================================
select pg_temp.ts('t1', 'authenticated', pg_temp.u(3), null, '  T6FB Evening  ', '21:00', '21:30', null, '3', 100);
select pg_temp.ts('t2', 'authenticated', pg_temp.u(3), null, 'T6FB Weekday', '21:30', '22:00',
                  extract(dow from pg_temp.d(4))::integer, '2', 100);
select pg_temp.ts('t3', 'authenticated', pg_temp.u(3), null, 'T6FB Open', '22:00', '22:30', null, null, 100);
select pg_temp.ts('t4', 'authenticated', pg_temp.u(3), null, 'T6FB Spare', '23:00', '23:30', null, '5', null);

-- t1 on d(3): two holding orders + one cancelled (does not hold) => booked 2. t3 on d(3): one holding order.
select pg_temp.mk(pg_temp.d(3), '21:00', '21:30', 'pending');
select pg_temp.mk(pg_temp.d(3), '21:00', '21:30', 'paid');
select pg_temp.mk(pg_temp.d(3), '21:00', '21:30', 'cancelled');
select pg_temp.mk(pg_temp.d(3), '22:00', '22:30', 'pending');

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
    perform pg_temp.sl('d_list_' || r.tag, r.role, r.uid, pg_temp.d(3), pg_temp.d(6));
    perform pg_temp.ts('d_ts_' || r.tag, r.role, r.uid, pg_temp.tid('t1'), 'HACKED', '21:00', '21:30', null, '99', 1);
    perform pg_temp.ts('d_tc_' || r.tag, r.role, r.uid, null, 'HACKED', '05:00', '06:00', null, '1', 1);
    perform pg_temp.ta('d_ta_' || r.tag, r.role, r.uid, pg_temp.tid('t4'), false, 'hack');
    perform pg_temp.os('d_os_' || r.tag, r.role, r.uid, pg_temp.tid('t4'), pg_temp.d(5), '1', false, null);
    perform pg_temp.oc('d_oc_' || r.tag, r.role, r.uid, pg_temp.tid('t4'), pg_temp.d(5), 'hack');
  end loop;
end
$d$;

-- =============================================================================
-- C. Template validation and updates
-- =============================================================================
select pg_temp.ts('tv_nolabel',  'authenticated', pg_temp.u(3), null, null, '05:00', '06:00', null, '1', null);
select pg_temp.ts('tv_blank',    'authenticated', pg_temp.u(3), null, '   ', '05:00', '06:00', null, '1', null);
select pg_temp.ts('tv_longlbl',  'authenticated', pg_temp.u(3), null, repeat('l', 81), '05:00', '06:00', null, '1', null);
select pg_temp.ts('tv_nostart',  'authenticated', pg_temp.u(3), null, 'T6FB X', null, '06:00', null, '1', null);
select pg_temp.ts('tv_noend',    'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', null, null, '1', null);
select pg_temp.ts('tv_endeq',    'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '05:00', null, '1', null);
select pg_temp.ts('tv_endbefore','authenticated', pg_temp.u(3), null, 'T6FB X', '06:00', '05:00', null, '1', null);
select pg_temp.ts('tv_dow7',     'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', 7, '1', null);
select pg_temp.ts('tv_downeg',   'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', -1, '1', null);
select pg_temp.ts('tv_capneg',   'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', null, '-1', null);
select pg_temp.ts('tv_capfrac',  'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', null, '2.5', null);
select pg_temp.ts('tv_caphuge',  'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', null, '100001', null);
select pg_temp.ts('tv_posneg',   'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', null, '1', -1);
select pg_temp.ts('tv_posbig',   'authenticated', pg_temp.u(3), null, 'T6FB X', '05:00', '06:00', null, '1', 1000001);
select pg_temp.ts('tv_u_missing','authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1b0000ffff', 'T6FB X', '05:00', '06:00', null, '1', null);
select pg_temp.ts('tv_u_blank',  'authenticated', pg_temp.u(3), pg_temp.tid('t1'), '  ', '21:00', '21:30', null, '3', null);
select pg_temp.ts('tv_u_window', 'authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening', '21:30', '21:00', null, '3', null);
-- identical save (label trimmed, position NULL = keep) -> changed=false
select pg_temp.ts('tu_same',     'authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening', '21:00', '21:30', null, '3', null);
-- window / weekday of a template that upcoming orders hold cannot move
select pg_temp.ts('tu_win_booked','authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening', '21:00', '21:45', null, '3', null);
select pg_temp.ts('tu_dow_booked','authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening', '21:00', '21:30', 1, '3', null);
-- allowed: rename only; lower capacity below bookings (documented: slot just reads full); restore
select pg_temp.ts('tu_label',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening 2', '21:00', '21:30', null, '3', null);
select pg_temp.ts('tu_lower',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening 2', '21:00', '21:30', null, '1', null);
select pg_temp.ts('tu_restore',  'authenticated', pg_temp.u(3), pg_temp.tid('t1'), 'T6FB Evening 2', '21:00', '21:30', null, '3', null);
-- t3: unlimited -> 10, position 100 -> 105
select pg_temp.ts('tu_cap',      'authenticated', pg_temp.u(3), pg_temp.tid('t3'), 'T6FB Open', '22:00', '22:30', null, '10', 105);
-- t4 has no orders: its window may move
select pg_temp.ts('tu_win_free', 'authenticated', pg_temp.u(3), pg_temp.tid('t4'), 'T6FB Spare', '23:00', '23:45', null, '5', null);

-- =============================================================================
-- D. Overrides on d(3) for t1 (booked 2, cap 3): validate / availability stay correct
-- =============================================================================
select pg_temp.vs('v_before',  pg_temp.d(3), '21:00', '21:30');
select pg_temp.os('os_below',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '1', false, null);
select pg_temp.os('os_zero',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '0', false, null);
select pg_temp.os('os_cap2',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '2', false, null);   -- = booked: allowed
select pg_temp.os('os_cap2b',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '2', false, null);   -- unchanged
select pg_temp.vs('v_full',    pg_temp.d(3), '21:00', '21:30');
select pg_temp.os('os_close',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), null, true, null);   -- closing with bookings is allowed
select pg_temp.vs('v_closed',  pg_temp.d(3), '21:00', '21:30');
select pg_temp.vs('v_closed_other_day', pg_temp.d(4), '21:00', '21:30');
select pg_temp.av('av_closed', pg_temp.d(3));
select pg_temp.os('os_close_cap','authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '5', true, null);
select pg_temp.oc('oc_d3',      'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), '  Slot reopened  ');
select pg_temp.oc('oc_d3_again','authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(3), 'again');
select pg_temp.vs('v_cleared', pg_temp.d(3), '21:00', '21:30');
select pg_temp.av('av_cleared', pg_temp.d(3));

-- d(5): capacity 1 on an empty date, note trimmed; then raised (update)
select pg_temp.os('os_d5',      'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), '1', false, '  busy day  ');
select pg_temp.vs('v_d5',      pg_temp.d(5), '21:00', '21:30');
select pg_temp.os('os_d5_up',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), '2', false, 'busy day');
-- t2 only runs on d(4)'s weekday
select pg_temp.os('os_t2_d4',   'authenticated', pg_temp.u(3), pg_temp.tid('t2'), pg_temp.d(4), '1', false, null);
select pg_temp.os('os_t2_d5',   'authenticated', pg_temp.u(3), pg_temp.tid('t2'), pg_temp.d(5), '1', false, null);
-- note-only override on d(6) (meaningful), then cleared
select pg_temp.os('os_note_d6', 'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(6), null, false, 'Driver short');
select pg_temp.oc('oc_d6',      'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(6), 'Driver back');

-- override validation
select pg_temp.os('ov_nulltpl',  'authenticated', pg_temp.u(3), null, pg_temp.d(5), '1', false, null);
select pg_temp.os('ov_nulldate', 'authenticated', pg_temp.u(3), pg_temp.tid('t1'), null, '1', false, null);
select pg_temp.os('ov_nullclosed','authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), '1', null, null);
select pg_temp.os('ov_capneg',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), '-1', false, null);
select pg_temp.os('ov_capfrac',  'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), '1.5', false, null);
select pg_temp.os('ov_caphuge',  'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), '100001', false, null);
select pg_temp.os('ov_longnote', 'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), '1', false, repeat('n', 301));
select pg_temp.os('ov_empty',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), null, false, '   ');
select pg_temp.os('ov_past',     'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(-1), '1', false, null);
select pg_temp.os('ov_far',      'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(366), '1', false, null);
select pg_temp.os('ov_unknown',  'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1b0000ffff', pg_temp.d(7), '1', false, null);
-- clear validation
select pg_temp.oc('ocv_noreason','authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), null);
select pg_temp.oc('ocv_blank',   'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), '   ');
select pg_temp.oc('ocv_long',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(5), repeat('r', 501));
select pg_temp.oc('ocv_nulltpl', 'authenticated', pg_temp.u(3), null, pg_temp.d(5), 'why');
select pg_temp.oc('ocv_nulldate','authenticated', pg_temp.u(3), pg_temp.tid('t1'), null, 'why');
select pg_temp.oc('ocv_none',    'authenticated', pg_temp.u(3), pg_temp.tid('t1'), pg_temp.d(7), 'nothing there');

-- =============================================================================
-- E. Template active/inactive; deactivated template and validate/availability
-- =============================================================================
select pg_temp.vs('v_t3_before', pg_temp.d(3), '22:00', '22:30');
select pg_temp.ta('ta_noreason', 'authenticated', pg_temp.u(3), pg_temp.tid('t3'), false, null);
select pg_temp.ta('ta_blank',    'authenticated', pg_temp.u(3), pg_temp.tid('t3'), false, '   ');
select pg_temp.ta('ta_long',     'authenticated', pg_temp.u(3), pg_temp.tid('t3'), false, repeat('r', 501));
select pg_temp.ta('ta_nullid',   'authenticated', pg_temp.u(3), null, false, 'why');
select pg_temp.ta('ta_nullact',  'authenticated', pg_temp.u(3), pg_temp.tid('t3'), null, 'why');
select pg_temp.ta('ta_unknown',  'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6f1b0000ffff', false, 'why');
select pg_temp.ta('ta_same',     'authenticated', pg_temp.u(3), pg_temp.tid('t3'), true, 'already active');
select pg_temp.ta('ta_off',      'authenticated', pg_temp.u(3), pg_temp.tid('t3'), false, '  Courier off  ');
select pg_temp.ta('ta_off_again','authenticated', pg_temp.u(3), pg_temp.tid('t3'), false, 'twice');
select pg_temp.vs('v_t3_off',    pg_temp.d(3), '22:00', '22:30');
select pg_temp.av('av_t3_off',   pg_temp.d(3));
select pg_temp.os('os_inactive', 'authenticated', pg_temp.u(3), pg_temp.tid('t3'), pg_temp.d(6), '1', false, null);
-- list while t3 is inactive and overrides exist (d5 cap 2 on t1, d4 cap 1 on t2)
select pg_temp.sl('sl_ok',       'authenticated', pg_temp.u(3), pg_temp.d(3), pg_temp.d(6));
select pg_temp.sl('sl_one_day',  'authenticated', pg_temp.u(3), pg_temp.d(3), pg_temp.d(3));
select pg_temp.sl('sl_31',       'authenticated', pg_temp.u(3), pg_temp.d(3), pg_temp.d(34));
select pg_temp.sl('sl_nullfrom', 'authenticated', pg_temp.u(3), null, pg_temp.d(6));
select pg_temp.sl('sl_nullto',   'authenticated', pg_temp.u(3), pg_temp.d(3), null);
select pg_temp.sl('sl_reversed', 'authenticated', pg_temp.u(3), pg_temp.d(6), pg_temp.d(3));
select pg_temp.sl('sl_wide',     'authenticated', pg_temp.u(3), pg_temp.d(3), pg_temp.d(35));
select pg_temp.ta('ta_on',       'authenticated', pg_temp.u(3), pg_temp.tid('t3'), true, 'Courier back');
select pg_temp.vs('v_t3_on',     pg_temp.d(3), '22:00', '22:30');
select pg_temp.av('av_t3_on',    pg_temp.d(3));

-- =============================================================================
-- F. Assertions
-- =============================================================================
do $t$
declare
  v_pre record;
  v_a uuid := pg_temp.u(3);
  v_sig text;
  r record;
  v_audit_new bigint;
  v_lst jsonb;
  v_o jsonb;
  v_row jsonb;
  v_t1 uuid := pg_temp.tid('t1');
  v_t2 uuid := pg_temp.tid('t2');
  v_t3 uuid := pg_temp.tid('t3');
  v_t4 uuid := pg_temp.tid('t4');
begin
  select * into v_pre from t_pre;

  -- ---- admin allowed ----
  perform pg_temp.ok(pg_temp.j('t1') ->> 'changed' = 'true' and pg_temp.j('t1') ->> 'created' = 'true', 'admin can create a template');
  perform pg_temp.ok(pg_temp.j('t1') -> 'template' ->> 'label' = 'T6FB Evening'
                     and pg_temp.j('t1') -> 'template' ->> 'is_active' = 'true'
                     and (pg_temp.j('t1') -> 'template' ->> 'capacity')::integer = 3
                     and (pg_temp.j('t1') -> 'template' ->> 'position')::integer = 100
                     and pg_temp.j('t1') -> 'template' ->> 'day_of_week' is null,
                     'created template: label trimmed, active, capacity, position, every day');
  perform pg_temp.ok((pg_temp.j('t2') -> 'template' ->> 'day_of_week')::integer = extract(dow from pg_temp.d(4))::integer, 'weekday template keeps its weekday');
  perform pg_temp.ok(pg_temp.j('t3') -> 'template' ->> 'capacity' is null, 'null capacity = unlimited');
  perform pg_temp.ok((pg_temp.j('t4') -> 'template' ->> 'position')::integer = 0, 'null position on create -> 0');
  perform pg_temp.ok(pg_temp.j('t1') -> 'template' ->> 'start_time' = '21:00:00' and pg_temp.j('t1') -> 'template' ->> 'end_time' = '21:30:00', 'window stored');

  -- ---- denied ----
  for r in select k from t_res where k like 'd\_%' loop
    if r.k like '%\_a' then
      perform pg_temp.ok(pg_temp.err(r.k) like '42501/%', 'anon denied: ' || r.k);
    else
      perform pg_temp.ok(pg_temp.err(r.k) = '42501/not_authorised', 'customer/staff denied with not_authorised: ' || r.k);
    end if;
  end loop;
  perform pg_temp.ok((select count(*) from t_res where k like 'd\_%') = 18, 'all 18 denied calls ran (3 roles x 6 calls incl. list)');
  perform pg_temp.ok((select label from public.delivery_slot_templates where id = v_t1) like 'T6FB Evening%'
                     and not exists (select 1 from public.delivery_slot_templates where label = 'HACKED'),
                     'denied calls changed and created no template');

  -- ---- template validation ----
  perform pg_temp.ok(pg_temp.err('tv_nolabel') = 'P0001/label_required', 'null label rejected');
  perform pg_temp.ok(pg_temp.err('tv_blank') = 'P0001/label_required', 'blank label rejected');
  perform pg_temp.ok(pg_temp.err('tv_longlbl') = 'P0001/label_too_long', 'label over 80 rejected');
  perform pg_temp.ok(pg_temp.err('tv_nostart') = 'P0001/invalid_window', 'null start rejected');
  perform pg_temp.ok(pg_temp.err('tv_noend') = 'P0001/invalid_window', 'null end rejected');
  perform pg_temp.ok(pg_temp.err('tv_endeq') = 'P0001/invalid_window', 'end equal to start rejected');
  perform pg_temp.ok(pg_temp.err('tv_endbefore') = 'P0001/invalid_window', 'end before start rejected');
  perform pg_temp.ok(pg_temp.err('tv_dow7') = 'P0001/invalid_weekday', 'weekday 7 rejected');
  perform pg_temp.ok(pg_temp.err('tv_downeg') = 'P0001/invalid_weekday', 'weekday -1 rejected');
  perform pg_temp.ok(pg_temp.err('tv_capneg') = 'P0001/invalid_capacity', 'negative capacity rejected');
  perform pg_temp.ok(pg_temp.err('tv_capfrac') = 'P0001/invalid_capacity', 'fractional capacity rejected');
  perform pg_temp.ok(pg_temp.err('tv_caphuge') = 'P0001/invalid_capacity', 'capacity over 100000 rejected');
  perform pg_temp.ok(pg_temp.err('tv_posneg') = 'P0001/invalid_position', 'negative position rejected');
  perform pg_temp.ok(pg_temp.err('tv_posbig') = 'P0001/invalid_position', 'position over 1000000 rejected');
  perform pg_temp.ok(pg_temp.err('tv_u_missing') = 'P0001/template_not_found', 'unknown template rejected on update');
  perform pg_temp.ok(pg_temp.err('tv_u_blank') = 'P0001/label_required', 'blank label rejected on update');
  perform pg_temp.ok(pg_temp.err('tv_u_window') = 'P0001/invalid_window', 'end before start rejected on update');
  perform pg_temp.ok(pg_temp.j('tu_same') ->> 'changed' = 'false' and pg_temp.j('tu_same') ->> 'created' = 'false', 'identical template save reports changed=false');
  perform pg_temp.ok(pg_temp.err('tu_win_booked') = 'P0001/template_has_bookings', 'window cannot move while upcoming orders hold it');
  perform pg_temp.ok(pg_temp.err('tu_dow_booked') = 'P0001/template_has_bookings', 'weekday cannot change while upcoming orders hold it');
  perform pg_temp.ok(pg_temp.j('tu_label') ->> 'changed' = 'true' and pg_temp.j('tu_label') -> 'template' ->> 'label' = 'T6FB Evening 2',
                     'rename of a booked template is allowed');
  perform pg_temp.ok((pg_temp.j('tu_lower') -> 'template' ->> 'capacity')::integer = 1
                     and (pg_temp.j('tu_restore') -> 'template' ->> 'capacity')::integer = 3,
                     'template capacity below bookings is allowed (slot just reads full) and can be restored');
  perform pg_temp.ok(pg_temp.j('tu_cap') -> 'template' ->> 'capacity' = '10' and pg_temp.j('tu_cap') -> 'template' ->> 'position' = '105',
                     'template capacity and position updated');
  perform pg_temp.ok(pg_temp.j('tu_win_free') -> 'template' ->> 'end_time' = '23:45:00', 'window of an unbooked template can move');
  perform pg_temp.ok((select count(*) from public.delivery_slot_templates) = v_pre.tpl_n + 4,
                     'rejected template calls created nothing (exactly t1..t4 beyond baseline)');

  -- ---- override: capacity below booked, clear error ----
  perform pg_temp.ok(pg_temp.err('os_below') = 'P0001/capacity_below_booked', 'capacity 1 with 2 booked refused');
  perform pg_temp.ok(pg_temp.msg('os_below') like '2 order(s) already hold this slot on %cannot be set below 2%close the slot instead%',
                     'capacity-below-booked message names the count and points to closing');
  perform pg_temp.ok(pg_temp.err('os_zero') = 'P0001/capacity_below_booked', 'capacity 0 with 2 booked refused');
  perform pg_temp.ok(pg_temp.j('os_cap2') ->> 'changed' = 'true' and pg_temp.j('os_cap2') ->> 'created' = 'true'
                     and (pg_temp.j('os_cap2') ->> 'booked_count')::integer = 2
                     and (pg_temp.j('os_cap2') -> 'override' ->> 'capacity')::integer = 2,
                     'capacity equal to booked (cancelled order not counted) is accepted; booked_count returned');
  perform pg_temp.ok(pg_temp.j('os_cap2b') ->> 'changed' = 'false', 'identical override save reports changed=false');
  perform pg_temp.ok(pg_temp.j('os_close') ->> 'changed' = 'true' and pg_temp.j('os_close') ->> 'created' = 'false'
                     and pg_temp.j('os_close') -> 'override' ->> 'is_active' = 'false'
                     and pg_temp.j('os_close') -> 'override' ->> 'capacity' is null,
                     'closing a slot with bookings is allowed (updates the existing override, capacity back to inherit)');
  perform pg_temp.ok(pg_temp.err('os_close_cap') = 'P0001/capacity_with_closed', 'closed + capacity together refused');

  -- ---- override: other validation ----
  perform pg_temp.ok(pg_temp.err('ov_nulltpl') = 'P0001/invalid_arguments', 'null template rejected');
  perform pg_temp.ok(pg_temp.err('ov_nulldate') = 'P0001/invalid_arguments', 'null date rejected');
  perform pg_temp.ok(pg_temp.err('ov_nullclosed') = 'P0001/invalid_arguments', 'null closed flag rejected');
  perform pg_temp.ok(pg_temp.err('ov_capneg') = 'P0001/invalid_capacity', 'negative override capacity rejected');
  perform pg_temp.ok(pg_temp.err('ov_capfrac') = 'P0001/invalid_capacity', 'fractional override capacity rejected');
  perform pg_temp.ok(pg_temp.err('ov_caphuge') = 'P0001/invalid_capacity', 'override capacity over 100000 rejected');
  perform pg_temp.ok(pg_temp.err('ov_longnote') = 'P0001/note_too_long', 'note over 300 rejected');
  perform pg_temp.ok(pg_temp.err('ov_empty') = 'P0001/override_empty', 'override with nothing to set rejected');
  perform pg_temp.ok(pg_temp.err('ov_past') = 'P0001/date_in_past', 'past date rejected');
  perform pg_temp.ok(pg_temp.err('ov_far') = 'P0001/date_too_far', 'date over 365 days ahead rejected');
  perform pg_temp.ok(pg_temp.err('ov_unknown') = 'P0001/template_not_found', 'unknown template rejected');
  perform pg_temp.ok(pg_temp.err('os_t2_d5') = 'P0001/template_not_on_date', 'weekday template refused on another weekday');
  perform pg_temp.ok(pg_temp.err('os_inactive') = 'P0001/template_inactive', 'inactive template refused');
  perform pg_temp.ok(pg_temp.j('os_t2_d4') ->> 'created' = 'true', 'weekday template accepted on its weekday');
  perform pg_temp.ok(pg_temp.j('os_d5') -> 'override' ->> 'note' = 'busy day' and (pg_temp.j('os_d5') ->> 'booked_count')::integer = 0,
                     'note trimmed; empty date has booked_count 0');
  perform pg_temp.ok(pg_temp.j('os_d5_up') ->> 'changed' = 'true' and pg_temp.j('os_d5_up') ->> 'created' = 'false'
                     and (pg_temp.j('os_d5_up') -> 'override' ->> 'capacity')::integer = 2, 'override capacity updated');
  perform pg_temp.ok(pg_temp.j('os_note_d6') ->> 'created' = 'true' and pg_temp.j('os_note_d6') -> 'override' ->> 'capacity' is null,
                     'note-only override is accepted');

  -- ---- clear ----
  perform pg_temp.ok(pg_temp.j('oc_d3') ->> 'changed' = 'true' and pg_temp.j('oc_d3') ->> 'previous_is_closed' = 'true'
                     and pg_temp.j('oc_d3') ->> 'previous_capacity' is null, 'clear returns the previous state');
  perform pg_temp.ok(pg_temp.err('oc_d3_again') = 'P0001/override_not_found', 'clearing a cleared override refused');
  perform pg_temp.ok(pg_temp.err('ocv_none') = 'P0001/override_not_found', 'clearing a date with no override refused');
  perform pg_temp.ok(pg_temp.err('ocv_noreason') = 'P0001/reason_required', 'clear: null reason rejected');
  perform pg_temp.ok(pg_temp.err('ocv_blank') = 'P0001/reason_required', 'clear: blank reason rejected');
  perform pg_temp.ok(pg_temp.err('ocv_long') = 'P0001/reason_too_long', 'clear: reason over 500 rejected');
  perform pg_temp.ok(pg_temp.err('ocv_nulltpl') = 'P0001/invalid_arguments', 'clear: null template rejected');
  perform pg_temp.ok(pg_temp.err('ocv_nulldate') = 'P0001/invalid_arguments', 'clear: null date rejected');
  perform pg_temp.ok((select count(*) from public.delivery_slot_overrides where template_id = v_t1 and slot_date = pg_temp.d(3)) = 1
                     and (select capacity is null and is_active and note is null from public.delivery_slot_overrides
                          where template_id = v_t1 and slot_date = pg_temp.d(3)),
                     'clear resets the row to neutral; nothing is deleted');
  perform pg_temp.ok((select count(*) from public.delivery_slot_overrides) = v_pre.ovr_n + 4,
                     'override rows: exactly the 4 created (d3 t1 neutral, d5 t1, d4 t2, d6 t1 neutral), none deleted');

  -- ---- template active ----
  perform pg_temp.ok(pg_temp.err('ta_noreason') = 'P0001/reason_required', 'template off: null reason rejected');
  perform pg_temp.ok(pg_temp.err('ta_blank') = 'P0001/reason_required', 'template off: blank reason rejected');
  perform pg_temp.ok(pg_temp.err('ta_long') = 'P0001/reason_too_long', 'template off: reason over 500 rejected');
  perform pg_temp.ok(pg_temp.err('ta_nullid') = 'P0001/invalid_arguments', 'template active: null id rejected');
  perform pg_temp.ok(pg_temp.err('ta_nullact') = 'P0001/invalid_arguments', 'template active: null state rejected');
  perform pg_temp.ok(pg_temp.err('ta_unknown') = 'P0001/template_not_found', 'template active: unknown template rejected');
  perform pg_temp.ok(pg_temp.err('ta_same') = 'P0001/status_unchanged', 'template active: no-op rejected');
  perform pg_temp.ok(pg_temp.err('ta_off_again') = 'P0001/status_unchanged', 'template deactivate twice rejected');
  perform pg_temp.ok(pg_temp.j('ta_off') ->> 'previous_is_active' = 'true' and pg_temp.j('ta_off') ->> 'is_active' = 'false'
                     and (pg_temp.j('ta_off') ->> 'upcoming_booked_orders')::integer = 1
                     and pg_temp.j('ta_on') ->> 'is_active' = 'true',
                     'template deactivate / reactivate results; deactivate reports the 1 upcoming booked order');

  -- ---- validate_delivery_slot() / get_delivery_slot_availability() before, closed, cleared, deactivated ----
  perform pg_temp.ok((pg_temp.j('v_before') ->> 'is_valid')::boolean and (pg_temp.j('v_before') ->> 'capacity')::integer = 3
                     and (pg_temp.j('v_before') ->> 'booked_count')::integer = 2 and (pg_temp.j('v_before') ->> 'remaining')::integer = 1,
                     'validate before: valid, capacity 3, booked 2, remaining 1');
  perform pg_temp.ok(not (pg_temp.j('v_full') ->> 'is_valid')::boolean and pg_temp.j('v_full') ->> 'error_code' = 'slot_full'
                     and pg_temp.j('v_full') ->> 'capacity_source' = 'override' and (pg_temp.j('v_full') ->> 'capacity')::integer = 2,
                     'validate with override capacity = booked: slot_full, source override');
  perform pg_temp.ok(not (pg_temp.j('v_closed') ->> 'is_valid')::boolean and pg_temp.j('v_closed') ->> 'error_code' = 'slot_closed'
                     and (pg_temp.j('v_closed') ->> 'is_closed')::boolean,
                     'validate after closing the date: slot_closed');
  perform pg_temp.ok((pg_temp.j('v_closed_other_day') ->> 'is_valid')::boolean, 'closing d(3) does not affect d(4)');
  perform pg_temp.ok(not (pg_temp.j('av_closed') ? v_t1::text) and (pg_temp.j('av_closed') ? v_t3::text),
                     'availability after closing: closed template gone, others still listed');
  perform pg_temp.ok((pg_temp.j('v_cleared') ->> 'is_valid')::boolean and (pg_temp.j('v_cleared') ->> 'capacity')::integer = 3
                     and pg_temp.j('v_cleared') ->> 'capacity_source' = 'template',
                     'validate after clearing the override: valid again, template capacity');
  perform pg_temp.ok(pg_temp.j('av_cleared') ? v_t1::text, 'availability after clearing: template listed again');
  perform pg_temp.ok((pg_temp.j('v_d5') ->> 'is_valid')::boolean and (pg_temp.j('v_d5') ->> 'capacity')::integer = 1
                     and pg_temp.j('v_d5') ->> 'capacity_source' = 'override', 'validate on d(5): override capacity 1 applies');
  perform pg_temp.ok((pg_temp.j('v_t3_before') ->> 'is_valid')::boolean, 'validate t3 before deactivation: valid');
  perform pg_temp.ok(not (pg_temp.j('v_t3_off') ->> 'is_valid')::boolean and pg_temp.j('v_t3_off') ->> 'error_code' = 'slot_inactive',
                     'validate after deactivating the template: slot_inactive');
  perform pg_temp.ok(not (pg_temp.j('av_t3_off') ? v_t3::text) and (pg_temp.j('av_t3_off') ? v_t1::text),
                     'availability after deactivating: inactive template gone');
  perform pg_temp.ok((pg_temp.j('v_t3_on') ->> 'is_valid')::boolean and (pg_temp.j('av_t3_on') ? v_t3::text),
                     'reactivated template is valid and listed again');
  perform pg_temp.ok((select count(*) from public.orders where delivery_slot_date = pg_temp.d(3) and delivery_slot_start = '22:00'
                      and status = 'pending') = 1, 'deactivating a template left its existing order untouched');

  -- ---- list ----
  v_lst := pg_temp.j('sl_ok');
  perform pg_temp.ok(jsonb_typeof(v_lst -> 'templates') = 'array' and jsonb_typeof(v_lst -> 'overrides') = 'array'
                     and jsonb_typeof(v_lst -> 'slots') = 'array' and v_lst ->> 'from' = pg_temp.d(3)::text and v_lst ->> 'to' = pg_temp.d(6)::text,
                     'list returns templates, overrides, slots and the range');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(v_lst -> 'templates') e where e ->> 'label' like 'T6FB%') = 4,
                     'list: all 4 fixture templates');
  perform pg_temp.ok((select (e ->> 'is_active')::boolean from jsonb_array_elements(v_lst -> 'templates') e where e ->> 'id' = v_t3::text) is false,
                     'list includes the inactive template, flagged inactive');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(v_lst -> 'overrides') e
                      where e ->> 'template_id' in (v_t1::text, v_t2::text, v_t3::text, v_t4::text)) = 2,
                     'list: overrides = d5 on t1 and d4 on t2; neutral (cleared) rows are not listed');
  select e into v_o from jsonb_array_elements(v_lst -> 'overrides') e
   where e ->> 'template_id' = v_t1::text and e ->> 'slot_date' = pg_temp.d(5)::text;
  perform pg_temp.ok((v_o ->> 'capacity')::integer = 2 and v_o ->> 'is_closed' = 'false' and v_o ->> 'template_label' = 'T6FB Evening 2'
                     and (v_o ->> 'booked_count')::integer = 0 and v_o ->> 'note' = 'busy day',
                     'list override row: capacity, is_closed, label, booked_count, note');
  select e into v_row from jsonb_array_elements(v_lst -> 'slots') e
   where e ->> 'template_id' = v_t1::text and e ->> 'slot_date' = pg_temp.d(3)::text;
  perform pg_temp.ok((v_row ->> 'booked_count')::integer = 2 and (v_row ->> 'effective_capacity')::integer = 3
                     and (v_row ->> 'template_capacity')::integer = 3 and v_row ->> 'is_closed' = 'false' and v_row ->> 'template_active' = 'true',
                     'list slot d3/t1: booked 2 (cancelled not counted), effective capacity 3, open');
  select e into v_row from jsonb_array_elements(v_lst -> 'slots') e
   where e ->> 'template_id' = v_t1::text and e ->> 'slot_date' = pg_temp.d(5)::text;
  perform pg_temp.ok((v_row ->> 'effective_capacity')::integer = 2 and (v_row ->> 'override_capacity')::integer = 2, 'list slot d5/t1: override capacity shown');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(v_lst -> 'slots') e where e ->> 'template_id' = v_t2::text) = 1
                     and (select e ->> 'slot_date' from jsonb_array_elements(v_lst -> 'slots') e where e ->> 'template_id' = v_t2::text) = pg_temp.d(4)::text,
                     'list: weekday template appears only on its weekday');
  select e into v_row from jsonb_array_elements(v_lst -> 'slots') e
   where e ->> 'template_id' = v_t3::text and e ->> 'slot_date' = pg_temp.d(3)::text;
  perform pg_temp.ok(v_row ->> 'template_active' = 'false' and (v_row ->> 'booked_count')::integer = 1,
                     'list: inactive template slot still shows its booked count');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(pg_temp.j('sl_one_day') -> 'slots') e where e ->> 'slot_date' <> pg_temp.d(3)::text) = 0,
                     'list for one day only returns that day');
  perform pg_temp.ok(pg_temp.j('sl_31') is not null, 'list accepts a 31-day gap');
  perform pg_temp.ok(pg_temp.err('sl_nullfrom') = 'P0001/invalid_date_range', 'list: null from rejected');
  perform pg_temp.ok(pg_temp.err('sl_nullto') = 'P0001/invalid_date_range', 'list: null to rejected');
  perform pg_temp.ok(pg_temp.err('sl_reversed') = 'P0001/invalid_date_range', 'list: to before from rejected');
  perform pg_temp.ok(pg_temp.err('sl_wide') = 'P0001/date_range_too_large', 'list: range over 31 days rejected');

  -- ---- audit: exact counts. Fixture admin only; denied/failed/unchanged calls wrote nothing. ----
  select count(*) into v_audit_new from public.admin_audit_log;
  perform pg_temp.ok(v_audit_new - v_pre.audit_n = 19, 'audit log grew by exactly 19 rows in the whole run');
  perform pg_temp.ok((select count(*) from public.admin_audit_log where actor_id = v_a) = 19, 'all 19 audit rows belong to the admin');
  perform pg_temp.ok((select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_created') = 4
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_updated') = 5
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_deactivated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_activated') = 1
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_created') = 4
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_updated') = 2
                     and (select count(*) from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_cleared') = 2,
                     'audit rows by action: template 4 created/5 updated/1 off/1 on, override 4 created/2 updated/2 cleared');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_deactivated'
                             and target_id = v_t3 and reason = 'Courier off'),
                     'template deactivate audit row: target, trimmed reason');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_updated'
                             and target_id = v_t3 and reason = 'T6FB Open: capacity: unlimited -> 10; position: 100 -> 105'),
                     'template update audit row summarises old -> new');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_template_updated'
                             and target_id = v_t4 and reason = 'T6FB Spare: end: 23:30:00 -> 23:45:00'),
                     'template window change audit row');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_created'
                             and target_id = (select id from public.delivery_slot_overrides where template_id = v_t1 and slot_date = pg_temp.d(5))
                             and reason like 'T6FB Evening 2 21:00:00-21:30:00 on %: capacity 1; closed false; 0 booked'),
                     'override create audit row: window, date, capacity, closed as true/false text, booked');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_updated'
                             and reason like '%on ' || pg_temp.d(3)::text || ': capacity: 2 -> inherit; closed: false -> true'),
                     'override close audit row: capacity 2 -> inherit and closed false -> true (boolean as text)');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_cleared'
                             and reason = 'Slot reopened | cleared override on ' || pg_temp.d(3)::text || ' (was capacity inherit; closed true)'),
                     'override clear audit row: trimmed reason first, previous state');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log where actor_id = v_a and action = 'delivery_slot_override_cleared'
                             and reason = 'Driver back | cleared override on ' || pg_temp.d(6)::text || ' (was capacity inherit; closed false)'),
                     'note-only override clear audit row');
  perform pg_temp.ok(not exists (select 1 from public.admin_audit_log
                                 where actor_id = v_a and (reason ~ ' -> [tf]($|;| )' or reason ~ ': [tf]($|;| )' or reason ~ 'closed [tf]($|;| )')),
                     'no audit text prints a boolean as t/f');
  perform pg_temp.ok(not exists (select 1 from public.admin_audit_log where actor_id = v_a and (reason is null or char_length(reason) > 500)),
                     'every audit reason is present and within 500 chars');

  -- ---- direct write grants were revoked by 20261005030000 (6F.4) ----
  perform pg_temp.ok(not has_column_privilege('authenticated', 'public.delivery_slot_templates', 'capacity', 'UPDATE')
                     and not has_column_privilege('authenticated', 'public.delivery_slot_overrides', 'capacity', 'UPDATE')
                     and not has_column_privilege('authenticated', 'public.delivery_slot_overrides', 'slot_date', 'INSERT'),
                     'direct column grants on slot tables are gone (6F.4)');
  perform pg_temp.ok(has_function_privilege('anon', 'public.validate_delivery_slot(date,time without time zone,time without time zone)', 'EXECUTE')
                     and has_function_privilege('anon', 'public.get_delivery_slot_availability(date,date)', 'EXECUTE'),
                     'customer-facing slot functions keep their grants');

  -- ---- function properties ----
  foreach v_sig in array array[
    'public.admin_list_delivery_slots(date,date)',
    'public.admin_save_delivery_slot_template(uuid,text,time without time zone,time without time zone,integer,numeric,integer)',
    'public.admin_set_delivery_slot_template_active(uuid,boolean,text)',
    'public.admin_save_delivery_slot_override(uuid,date,numeric,boolean,text)',
    'public.admin_clear_delivery_slot_override(uuid,date,text)'] loop
    perform pg_temp.ok((select p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                        from pg_proc p where p.oid = v_sig::regprocedure)
                       and not has_function_privilege('anon', v_sig, 'EXECUTE')
                       and has_function_privilege('authenticated', v_sig, 'EXECUTE'),
                       'SECURITY DEFINER, pinned search_path, anon denied, authenticated granted: ' || v_sig);
  end loop;

  raise notice 'ALL PHASE 6F.1B DELIVERY ADMIN SLOT TESTS PASSED';
end
$t$;

rollback;
