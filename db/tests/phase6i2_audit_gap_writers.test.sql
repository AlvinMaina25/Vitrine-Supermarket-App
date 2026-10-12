-- Phase 6I.2 test: the seven audit-gap writers. WRITTEN, NOT RUN.
-- Needs migrations up to 20261005100000 (Phase 6I.2) applied (Supabase-style auth schema).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'A6'. Audit rows are read ONLY as the table owner (this script's own
-- session, role reset) or through admin_list_audit_log(); never directly as authenticated.
-- Functions covered: admin_set_order_status, admin_create_product, admin_update_product,
--   admin_set_product_active, admin_create_product_variant, admin_update_product_variant,
--   admin_adjust_inventory.
begin;

do $pre$
begin
  if to_regprocedure('public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)') is null
     or not exists (select 1 from pg_proc p where p.oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure
                    and p.prosrc like '%admin_audit_log%') then
    raise exception 'Phase 6I.2 test: apply 20261005090000 (6I.1) and 20261005100000 (6I.2) first.';
  end if;
end
$pre$;

create temp table t_res (k text primary key, res text, err text, state text, detail text);
create temp table t_ids (k text primary key, v text);
create temp table t_q (fn text primary key, q text);
create temp table t_aud (k text primary key, n bigint);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: % || stored results: %', n,
      (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'res', left(res, 200), 'err', err, 'state', state, 'detail', detail)), '[]'::jsonb) from t_res);
  end if;
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

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a20000000' || lpad(n::text, 2, '0'))::uuid $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$ select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;
create or replace function pg_temp.id(k text) returns text language sql as $$ select v from t_ids where t_ids.k = id.k $$;
-- Audit reads as the table owner (this session; run() always resets the role).
create or replace function pg_temp.audn(p_target uuid, p_action text) returns bigint language sql as $$
  select count(*) from public.admin_audit_log a where a.target_id = p_target and a.action = p_action $$;
create or replace function pg_temp.total() returns bigint language sql as $$ select count(*) from public.admin_audit_log $$;

-- Fixtures: 1 customer, 2 staff, 3 admin, 4 second admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6a-cust@example.test',   'authenticated', 'authenticated', '{"full_name":"A6 Cust"}'),
  (pg_temp.u(2), 't6a-staff@example.test',  'authenticated', 'authenticated', '{"full_name":"A6 Staff"}'),
  (pg_temp.u(3), 't6a-admin@example.test',  'authenticated', 'authenticated', '{"full_name":"A6 Admin"}'),
  (pg_temp.u(4), 't6a-admin2@example.test', 'authenticated', 'authenticated', '{"full_name":"A6 Admin2"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin'), (pg_temp.u(4), 'admin');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-6a200000b001', 'a6-base',  'A6 Base',  1000, 10, true, true),
  ('00000000-0000-4000-8000-6a200000b002', 'a6-other', 'A6 Other', 1000, 10, true, true);
insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, attributes, position, is_active) values
  ('00000000-0000-4000-8000-6a200000c001', '00000000-0000-4000-8000-6a200000b001', 'A6 Var', 500, 5, '{}'::jsonb, 0, true);
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('a6_pick', 'A6 pickup', 0, null, 0, false, false, true);

-- A real order, created by the customer through create_order() (pickup, cash on delivery).
select pg_temp.run('mk_order', 'authenticated', pg_temp.u(1),
  $$select public.create_order(p_items => '[{"product_id":"00000000-0000-4000-8000-6a200000b001","quantity":1}]'::jsonb, p_delivery_method => 'a6_pick', p_payment_method => 'cash_on_delivery', p_idempotency_key => 'A6-key-1')::text$$);

insert into t_ids values
  ('order',   (select res from t_res where k = 'mk_order')),
  ('status0', (select o.status::text from public.orders o where o.id = (select res::uuid from t_res where k = 'mk_order')));

-- Valid-shaped call for each function (used for the "rejected caller" matrix).
insert into t_q
select fn, q from (values
  ('os', format($f$select public.admin_set_order_status(%L::uuid, 'cancelled', 'A6-SECRET-NOTE', false)::text$f$, pg_temp.id('order'))),
  ('cp', $f$select public.admin_create_product('A6-SECRET-NAME', 'a6-new', 1500, null, 'A6-SECRET-DESC', 'A6-SECRET-BRAND', 'A6-SECRET-SKU', 'kg', 2000)::text$f$),
  ('up', $f$select public.admin_update_product('00000000-0000-4000-8000-6a200000b001', '{"name":"A6-SECRET-NAME-2","price_cents":1200}'::jsonb)::text$f$),
  ('sa', $f$select public.admin_set_product_active('00000000-0000-4000-8000-6a200000b001', false)::text$f$),
  ('cv', $f$select public.admin_create_product_variant('00000000-0000-4000-8000-6a200000b001', 'A6-SECRET-VNAME', 700, 'A6-SECRET-VSKU', 900, '{"s":"A6-SECRET-ATTR"}'::jsonb, 1)::text$f$),
  ('uv', $f$select public.admin_update_product_variant('00000000-0000-4000-8000-6a200000c001', '{"price_cents":600,"name":"A6-SECRET-VNAME-2"}'::jsonb)::text$f$),
  ('ai', $f$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b001', -3, 'A6 stock count', null, 'A6-SECRET-NOTE')::text$f$)
) v(fn, q);

insert into t_aud select 'start', pg_temp.total();

-- ---------------------------------------------------------------------------------------------
-- 1. REJECTED calls: customer, anon, staff, each against all seven functions (valid arguments).
-- ---------------------------------------------------------------------------------------------
do $r$
declare c record; f record;
begin
  for c in select * from (values ('cust', 'authenticated', pg_temp.u(1)),
                                 ('anon', 'anon', null::uuid),
                                 ('staff', 'authenticated', pg_temp.u(2))) x(who, role, uid) loop
    for f in select * from t_q loop
      perform pg_temp.run('rej_' || c.who || '_' || f.fn, c.role, c.uid, f.q);
    end loop;
  end loop;
end
$r$;
insert into t_aud select 'after_rejected', pg_temp.total();

-- ---------------------------------------------------------------------------------------------
-- 2. FAILED calls by a real admin (gate passes, then validation / state refuses).
-- ---------------------------------------------------------------------------------------------
select pg_temp.run('f_os_nf',    'authenticated', pg_temp.u(3), $$select public.admin_set_order_status('00000000-0000-4000-8000-6a29999999ff'::uuid, 'cancelled', null, false)::text$$);
select pg_temp.run('f_os_pref',  'authenticated', pg_temp.u(3), format($$select public.admin_set_order_status(%L::uuid, 'cancelled', 'Admin override: x', false)::text$$, pg_temp.id('order')));
select pg_temp.run('f_cp_slug',  'authenticated', pg_temp.u(3), $$select public.admin_create_product('A6 Dup', 'a6-base', 100)::text$$);
select pg_temp.run('f_cp_price', 'authenticated', pg_temp.u(3), $$select public.admin_create_product('A6 Neg', 'a6-neg', -1)::text$$);
select pg_temp.run('f_up_nf',    'authenticated', pg_temp.u(3), $$select public.admin_update_product('00000000-0000-4000-8000-6a29999999ff'::uuid, '{"price_cents":1}'::jsonb)::text$$);
select pg_temp.run('f_up_field', 'authenticated', pg_temp.u(3), $$select public.admin_update_product('00000000-0000-4000-8000-6a200000b001'::uuid, '{"stock_quantity":5}'::jsonb)::text$$);
select pg_temp.run('f_up_dup',   'authenticated', pg_temp.u(3), $$select public.admin_update_product('00000000-0000-4000-8000-6a200000b001'::uuid, '{"slug":"a6-other"}'::jsonb)::text$$);
select pg_temp.run('f_sa_nf',    'authenticated', pg_temp.u(3), $$select public.admin_set_product_active('00000000-0000-4000-8000-6a29999999ff'::uuid, false)::text$$);
select pg_temp.run('f_sa_null',  'authenticated', pg_temp.u(3), $$select public.admin_set_product_active('00000000-0000-4000-8000-6a200000b001'::uuid, null)::text$$);
select pg_temp.run('f_cv_nf',    'authenticated', pg_temp.u(3), $$select public.admin_create_product_variant('00000000-0000-4000-8000-6a29999999ff'::uuid, 'A6 V', 100)::text$$);
select pg_temp.run('f_cv_price', 'authenticated', pg_temp.u(3), $$select public.admin_create_product_variant('00000000-0000-4000-8000-6a200000b001'::uuid, 'A6 V', -5)::text$$);
select pg_temp.run('f_uv_nf',    'authenticated', pg_temp.u(3), $$select public.admin_update_product_variant('00000000-0000-4000-8000-6a29999999ff'::uuid, '{"price_cents":1}'::jsonb)::text$$);
select pg_temp.run('f_uv_field', 'authenticated', pg_temp.u(3), $$select public.admin_update_product_variant('00000000-0000-4000-8000-6a200000c001'::uuid, '{"stock_quantity":1}'::jsonb)::text$$);
select pg_temp.run('f_ai_neg',   'authenticated', pg_temp.u(3), $$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b001'::uuid, -999, 'A6 too much')::text$$);
select pg_temp.run('f_ai_zero',  'authenticated', pg_temp.u(3), $$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b001'::uuid, 0, 'A6 zero')::text$$);
select pg_temp.run('f_ai_noreas','authenticated', pg_temp.u(3), $$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b001'::uuid, 1, '   ')::text$$);
select pg_temp.run('f_ai_mism',  'authenticated', pg_temp.u(3), $$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b002'::uuid, 1, 'A6 mismatch', '00000000-0000-4000-8000-6a200000c001'::uuid)::text$$);
insert into t_aud select 'after_failed', pg_temp.total();

-- ---------------------------------------------------------------------------------------------
-- 3. NO-OP calls by a real admin (succeed, change nothing, so write no audit row).
--    admin_adjust_inventory has no no-op: a zero adjustment is rejected (covered in section 2).
-- ---------------------------------------------------------------------------------------------
select pg_temp.run('n_os', 'authenticated', pg_temp.u(3),
  format($$select public.admin_set_order_status(%L::uuid, %L::public.order_status, null, false)::text$$, pg_temp.id('order'), pg_temp.id('status0')));
select pg_temp.run('n_sa', 'authenticated', pg_temp.u(3), $$select public.admin_set_product_active('00000000-0000-4000-8000-6a200000b001'::uuid, true)::text$$);
select pg_temp.run('n_up', 'authenticated', pg_temp.u(3), $$select public.admin_update_product('00000000-0000-4000-8000-6a200000b001'::uuid, '{"name":"A6 Base","price_cents":1000}'::jsonb)::text$$);
select pg_temp.run('n_uv', 'authenticated', pg_temp.u(3), $$select public.admin_update_product_variant('00000000-0000-4000-8000-6a200000c001'::uuid, '{"price_cents":500,"name":"A6 Var"}'::jsonb)::text$$);
insert into t_aud select 'after_noop', pg_temp.total();

-- ---------------------------------------------------------------------------------------------
-- 4. SUCCESSFUL calls (one each; inventory twice: product-level by admin 1, variant-level by admin 2).
-- ---------------------------------------------------------------------------------------------
select pg_temp.run('s_os', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'os'));
select pg_temp.run('s_cp', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'cp'));
select pg_temp.run('s_up', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'up'));
select pg_temp.run('s_sa', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'sa'));
select pg_temp.run('s_cv', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'cv'));
select pg_temp.run('s_uv', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'uv'));
select pg_temp.run('s_ai', 'authenticated', pg_temp.u(3), (select q from t_q where fn = 'ai'));
select pg_temp.run('s_aiv', 'authenticated', pg_temp.u(4),
  $$select public.admin_adjust_inventory('00000000-0000-4000-8000-6a200000b001'::uuid, 2, 'A6 stock count', '00000000-0000-4000-8000-6a200000c001'::uuid, 'A6-SECRET-NOTE')::text$$);
insert into t_aud select 'after_success', pg_temp.total();

-- Read the order's audit rows through the only browser read path, as the admin.
select pg_temp.run('lst_order', 'authenticated', pg_temp.u(3),
  format($$select public.admin_list_audit_log(p_target_id => %L::uuid)::text$$, pg_temp.id('order')));

do $t$
declare
  c_p constant uuid := '00000000-0000-4000-8000-6a200000b001';
  c_v constant uuid := '00000000-0000-4000-8000-6a200000c001';
  v_order uuid := pg_temp.id('order')::uuid;
  v_newp uuid;
  v_newv uuid;
  v_sig text;
  v_a public.admin_audit_log%rowtype;
  v_n bigint;
  v_sigs constant text[] := array[
    'public.admin_set_order_status(uuid,public.order_status,text,boolean)',
    'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)',
    'public.admin_update_product(uuid,jsonb)',
    'public.admin_set_product_active(uuid,boolean)',
    'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)',
    'public.admin_update_product_variant(uuid,jsonb)',
    'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'];
  s_start bigint := (select n from t_aud where k = 'start');
  s_rej   bigint := (select n from t_aud where k = 'after_rejected');
  s_fail  bigint := (select n from t_aud where k = 'after_failed');
  s_noop  bigint := (select n from t_aud where k = 'after_noop');
  s_succ  bigint := (select n from t_aud where k = 'after_success');
begin
  perform pg_temp.ok(v_order is not null, 'fixture: the customer created an order');

  -- ---- rejected: none, for all 21 (3 callers x 7 functions) ----
  perform pg_temp.ok((select count(*) from t_res where k like 'rej\_%' and err is not null and state = '42501') = 21,
                     'all 21 non-admin calls (customer, anon, staff x 7 functions) are refused with 42501');
  perform pg_temp.ok(s_rej = s_start, 'rejected calls wrote NO audit rows');

  -- ---- failed: none ----
  perform pg_temp.ok((select count(*) from t_res where k like 'f\_%' and err is not null) = 17,
                     'all 17 admin failure cases raised an error');
  perform pg_temp.ok(pg_temp.err('f_os_nf') = 'P0001/order_not_found', 'order not found refused');
  perform pg_temp.ok(pg_temp.err('f_os_pref') = 'P0001/note_reserved_prefix', 'reserved note prefix refused');
  perform pg_temp.ok(pg_temp.err('f_cp_slug') = '23505/slug_taken', 'duplicate slug refused');
  perform pg_temp.ok(pg_temp.err('f_cp_price') = 'P0001/invalid_arguments', 'negative price refused');
  perform pg_temp.ok(pg_temp.err('f_up_nf') = 'P0001/product_not_found', 'update of unknown product refused');
  perform pg_temp.ok(pg_temp.err('f_up_field') = 'P0001/unsupported_field', 'unsupported product field refused');
  perform pg_temp.ok(pg_temp.err('f_up_dup') = '23505/slug_taken', 'update to a taken slug refused');
  perform pg_temp.ok(pg_temp.err('f_sa_nf') = 'P0001/product_not_found', 'activation of unknown product refused');
  perform pg_temp.ok(pg_temp.err('f_sa_null') = 'P0001/invalid_arguments', 'null activation value refused');
  perform pg_temp.ok(pg_temp.err('f_cv_nf') = 'P0001/product_not_found', 'variant for unknown product refused');
  perform pg_temp.ok(pg_temp.err('f_cv_price') = 'P0001/invalid_arguments', 'variant negative price refused');
  perform pg_temp.ok(pg_temp.err('f_uv_nf') = 'P0001/variant_not_found', 'update of unknown variant refused');
  perform pg_temp.ok(pg_temp.err('f_uv_field') = 'P0001/unsupported_field', 'unsupported variant field refused');
  perform pg_temp.ok(pg_temp.err('f_ai_neg') = 'P0001/negative_stock_not_allowed', 'negative stock refused');
  perform pg_temp.ok(pg_temp.err('f_ai_zero') = 'P0001/zero_adjustment_not_allowed', 'zero adjustment refused');
  perform pg_temp.ok(pg_temp.err('f_ai_noreas') = 'P0001/invalid_arguments', 'blank inventory reason refused');
  perform pg_temp.ok(pg_temp.err('f_ai_mism') = 'P0001/variant_product_mismatch', 'variant/product mismatch refused');
  perform pg_temp.ok(s_fail = s_rej, 'failed calls wrote NO audit rows');

  -- ---- no-op: none ----
  perform pg_temp.ok(pg_temp.err('n_os') is null and pg_temp.j('n_os') ->> 'changed' = 'false', 'order no-op: already in that status, changed = false');
  perform pg_temp.ok(pg_temp.err('n_sa') is null and pg_temp.j('n_sa') -> 'product' ->> 'is_active' = 'true', 'activation no-op: value already true');
  perform pg_temp.ok(pg_temp.err('n_up') is null, 'product patch that changes nothing still succeeds');
  perform pg_temp.ok(pg_temp.err('n_uv') is null, 'variant patch that changes nothing still succeeds');
  perform pg_temp.ok(s_noop = s_fail, 'no-op calls wrote NO audit rows');

  -- ---- success: exactly one row each ----
  perform pg_temp.ok(pg_temp.err('s_os') is null and pg_temp.j('s_os') ->> 'changed' = 'true', 'order status change succeeded');
  v_newp := (pg_temp.j('s_cp') -> 'product' ->> 'id')::uuid;
  v_newv := (pg_temp.j('s_cv') -> 'variant' ->> 'id')::uuid;
  perform pg_temp.ok(v_newp is not null and v_newv is not null and pg_temp.err('s_up') is null and pg_temp.err('s_sa') is null
                     and pg_temp.err('s_uv') is null and pg_temp.err('s_ai') is null and pg_temp.err('s_aiv') is null,
                     'all eight successful calls succeeded');
  perform pg_temp.ok(s_succ = s_noop + 8, 'exactly 8 audit rows for 8 successful mutations (one each)');

  perform pg_temp.ok(pg_temp.audn(v_order, 'order_status_changed') = 1, 'admin_set_order_status: one row');
  perform pg_temp.ok(pg_temp.audn(v_newp, 'product_created') = 1, 'admin_create_product: one row');
  perform pg_temp.ok(pg_temp.audn(c_p, 'product_updated') = 1, 'admin_update_product: one row');
  perform pg_temp.ok(pg_temp.audn(c_p, 'product_deactivated') = 1 and pg_temp.audn(c_p, 'product_activated') = 0,
                     'admin_set_product_active: one product_deactivated row, no product_activated row');
  perform pg_temp.ok(pg_temp.audn(v_newv, 'product_variant_created') = 1, 'admin_create_product_variant: one row');
  perform pg_temp.ok(pg_temp.audn(c_v, 'product_variant_updated') = 1, 'admin_update_product_variant: one row');
  perform pg_temp.ok(pg_temp.audn(c_p, 'inventory_adjusted') = 1 and pg_temp.audn(c_v, 'inventory_adjusted') = 1,
                     'admin_adjust_inventory: one row (product-level, targeting the product) and one (variant-level, targeting the variant)');

  -- ---- actor_id = auth.uid() ----
  perform pg_temp.ok((select count(*) from public.admin_audit_log
                      where actor_id = pg_temp.u(3)
                        and ((target_id = v_order and action = 'order_status_changed')
                          or (target_id = v_newp and action = 'product_created')
                          or (target_id = c_p and action in ('product_updated', 'product_deactivated', 'inventory_adjusted'))
                          or (target_id = v_newv and action = 'product_variant_created')
                          or (target_id = c_v and action = 'product_variant_updated'))) = 7,
                     'the seven admin-1 rows carry actor_id = that admin''s auth.uid()');
  perform pg_temp.ok((select actor_id from public.admin_audit_log where target_id = c_v and action = 'inventory_adjusted') = pg_temp.u(4),
                     'the variant-level inventory row carries admin 2''s auth.uid() (actor follows the caller)');

  -- ---- row content: exact, non-sensitive ----
  select * into v_a from public.admin_audit_log where target_id = v_order and action = 'order_status_changed';
  perform pg_temp.ok(v_a.reason like pg_temp.id('status0') || ' -> cancelled%', 'order row: old -> new status only');
  select * into v_a from public.admin_audit_log where target_id = v_newp and action = 'product_created';
  perform pg_temp.ok(v_a.reason = 'price_cents 1500; compare_at_price_cents 2000', 'create product row: prices only');
  select * into v_a from public.admin_audit_log where target_id = c_p and action = 'product_updated';
  perform pg_temp.ok(v_a.reason = 'name; price_cents 1000 -> 1200', 'update product row: field NAME for text, old -> new for price');
  select * into v_a from public.admin_audit_log where target_id = c_p and action = 'product_deactivated';
  perform pg_temp.ok(v_a.reason = 'is_active true -> false', 'activation row: is_active old -> new');
  select * into v_a from public.admin_audit_log where target_id = v_newv and action = 'product_variant_created';
  perform pg_temp.ok(v_a.reason = format('product %s; price_cents 700; compare_at_price_cents 900', c_p), 'create variant row: parent id and prices only');
  select * into v_a from public.admin_audit_log where target_id = c_v and action = 'product_variant_updated';
  perform pg_temp.ok(v_a.reason = format('product %s: name; price_cents 500 -> 600', c_p), 'update variant row: field NAME for text, old -> new for price');
  select * into v_a from public.admin_audit_log where target_id = c_p and action = 'inventory_adjusted';
  perform pg_temp.ok(v_a.reason = 'product delta -3; stock 10 -> 7; A6 stock count', 'inventory row (product): delta, old -> new stock, short reason');
  select * into v_a from public.admin_audit_log where target_id = c_v and action = 'inventory_adjusted';
  perform pg_temp.ok(v_a.reason = format('variant of product %s delta 2; stock 5 -> 7; A6 stock count', c_p), 'inventory row (variant): delta, old -> new stock, short reason');

  -- ---- no sensitive fields: the table has only six columns and no value text leaks into reason ----
  perform pg_temp.ok((select array_agg(column_name::text order by column_name) from information_schema.columns
                      where table_schema = 'public' and table_name = 'admin_audit_log')
                     = array['action', 'actor_id', 'created_at', 'id', 'reason', 'target_id'],
                     'audit rows have only id, actor_id, action, target_id, reason, created_at (no payload column)');
  select count(*) into v_n from public.admin_audit_log
  where actor_id in (pg_temp.u(3), pg_temp.u(4))
    and (reason ~* 'secret'                                        -- every fixture free-text / text value carries this
         or reason ~ '@'                                           -- no emails
         or reason ~* '(token|password|secret|bearer|authorization|card|cvv|phone|msisdn|email|api[_-]?key)'
         or reason ~ '[{}\[\]]'                                    -- no raw JSON payloads
         or char_length(reason) > 500);
  perform pg_temp.ok(v_n = 0, 'no audit reason contains a fixture text value, note, email, phone, token, card data or raw payload');
  perform pg_temp.ok(not exists (select 1 from public.admin_audit_log
                                 where actor_id in (pg_temp.u(3), pg_temp.u(4))
                                   and (reason like '%A6 Base%' or reason like '%A6 Var%' or reason like '%a6-new%')),
                     'no product name, variant name or slug appears in any audit reason');

  -- ---- read path: admin_list_audit_log (admin only) shows the same row; browser roles cannot read the table ----
  perform pg_temp.ok(pg_temp.err('lst_order') is null
                     and (pg_temp.j('lst_order') ->> 'total_count')::int = 1
                     and pg_temp.j('lst_order') -> 'entries' -> 0 ->> 'action' = 'order_status_changed'
                     and pg_temp.j('lst_order') -> 'entries' -> 0 ->> 'actor_id' = pg_temp.u(3)::text,
                     'admin_list_audit_log returns the order row with the admin as actor');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.admin_audit_log', 'SELECT')
                     and not has_table_privilege('anon', 'public.admin_audit_log', 'SELECT')
                     and not has_table_privilege('authenticated', 'public.admin_audit_log', 'INSERT'),
                     'browser roles have no direct SELECT or INSERT on admin_audit_log (6I.1 intact)');

  -- ---- grants unchanged: authenticated yes, anon no, PUBLIC no; definer + pinned search_path ----
  foreach v_sig in array v_sigs loop
    perform pg_temp.ok(has_function_privilege('authenticated', v_sig, 'EXECUTE')
                       and not has_function_privilege('anon', v_sig, 'EXECUTE')
                       and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                                       where p.oid = v_sig::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
                       'grants unchanged (authenticated yes, anon no, PUBLIC no): ' || v_sig);
    perform pg_temp.ok(exists (select 1 from pg_proc p
                               where p.oid = v_sig::regprocedure and p.prosecdef and p.provolatile = 'v'
                                 and p.prorettype = 'jsonb'::regtype
                                 and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'),
                       'still SECURITY DEFINER, VOLATILE, jsonb, pinned search_path: ' || v_sig);
  end loop;
  perform pg_temp.ok((select count(*) from pg_proc where proname in ('admin_set_order_status', 'admin_create_product',
                        'admin_update_product', 'admin_set_product_active', 'admin_create_product_variant',
                        'admin_update_product_variant', 'admin_adjust_inventory') and pronamespace = 'public'::regnamespace) = 7,
                     'exactly one overload of each of the seven functions');
end
$t$;

rollback;
