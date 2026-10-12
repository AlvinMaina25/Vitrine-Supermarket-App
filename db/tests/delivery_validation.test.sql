-- =============================================================================
-- PHASE 4B.1 database tests: delivery validation, fee authority, authorisation.
--
-- HOW TO RUN (needs a Supabase/Postgres database with ALL migrations through
-- 20260930040000_delivery_validation.sql applied; use a dev or branch database):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/delivery_validation.test.sql
--
-- or paste into the Supabase SQL editor. Everything runs in ONE transaction that is
-- rolled back at the end, so nothing is left behind. Any failed check raises an
-- exception ("FAIL: <name>") and aborts the run; every passing check prints
-- "PASS: <name>". A run that reaches the final "ALL DELIVERY VALIDATION TESTS PASSED"
-- notice passed everything.
--
-- Fixtures use their own codes (tv_*, zone codes tv-*) and never touch the seeded
-- standard / express / pickup methods.
-- =============================================================================
begin;

create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_name;
  end if;
  raise notice 'PASS: %', p_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (inserted as the migration owner, which bypasses RLS)
-- ---------------------------------------------------------------------------
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('tv_deliv', 'TV delivery',  25000, 500000,       0, true,  true,  true),
  ('tv_minm',  'TV min order', 10000, null,    100000, true,  true,  true),
  ('tv_pick',  'TV pickup',        0, null,         0, true,  false, true),
  ('tv_off',   'TV inactive',  25000, null,         0, true,  true,  false);

insert into public.delivery_zones (id, code, name, is_active) values
  ('00000000-0000-4000-8000-0000000000a1', 'tv-zone-a',   'TV Zone A (rules)',    true),
  ('00000000-0000-4000-8000-0000000000b2', 'tv-zone-b',   'TV Zone B (no rules)', true),
  ('00000000-0000-4000-8000-0000000000c3', 'tv-zone-off', 'TV Zone inactive',     false);

insert into public.delivery_zone_fees
  (id, zone_id, method_code, fee_cents, free_over_cents, min_order_cents, is_active)
values
  -- zone A + tv_deliv: dearer fee, higher free threshold, minimum of its own
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000a1',
   'tv_deliv', 40000, 800000, 150000, true),
  -- zone A + tv_minm: a LOWER minimum than the method's must not lower it
  ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000a1',
   'tv_minm', 5000, null, 0, true),
  -- a rule on the inactive zone must never be used
  ('00000000-0000-4000-8000-0000000000f3', '00000000-0000-4000-8000-0000000000c3',
   'tv_deliv', 1, 1, 0, true);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000c001', 'tv-customer@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000c002', 'tv-staff@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000c003', 'tv-admin@example.test',    'authenticated', 'authenticated');

insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-00000000c002', 'staff'),
  ('00000000-0000-4000-8000-00000000c003', 'admin');

-- ---------------------------------------------------------------------------
-- 1. Zone validation
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 900000);
  perform pg_temp.ok(r.is_valid and r.error_code is null, 'valid active zone is accepted');
  perform pg_temp.ok(r.zone_code = 'tv-zone-a' and r.method_code = 'tv_deliv',
    'valid selection returns zone and method identity');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-00000000dead', 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'zone_unknown' and r.fee_cents is null,
    'unknown zone is rejected with no fee');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000c3', 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'zone_inactive' and r.fee_cents is null,
    'inactive zone is rejected with no fee');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 149999);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'below_minimum_order'
    and r.min_order_cents = 150000 and r.fee_cents is null,
    'zone minimum order violation is rejected and reports the minimum');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 150000);
  perform pg_temp.ok(r.is_valid, 'subtotal exactly at the zone minimum is accepted');

  select * into r from public.validate_delivery_selection('tv_deliv', null, 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'zone_required',
    'address method without a zone is rejected (cannot dodge the zone fee by omitting it)');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Method validation
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.validate_delivery_selection(
    'tv_pick', null, 0);
  perform pg_temp.ok(r.is_valid and r.fee_cents = 0, 'valid active method (pickup, no zone needed)');

  select * into r from public.validate_delivery_selection(
    'tv_nope', '00000000-0000-4000-8000-0000000000a1', 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'method_unknown', 'unknown method is rejected');

  select * into r from public.validate_delivery_selection(
    'tv_off', '00000000-0000-4000-8000-0000000000a1', 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'method_inactive', 'inactive method is rejected');

  select * into r from public.validate_delivery_selection(
    null, '00000000-0000-4000-8000-0000000000a1', 900000);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'method_required', 'missing method is rejected');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', -1);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'invalid_subtotal', 'negative subtotal is rejected');

  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', null);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'invalid_subtotal', 'NULL subtotal is rejected');

  select * into r from public.validate_delivery_selection('tv_pick', '00000000-0000-4000-8000-0000000000c3', 0);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'zone_inactive',
    'an inactive zone is rejected even for a method that does not need a zone');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Authoritative fee (must equal resolve_delivery_fee, the single calculation)
-- ---------------------------------------------------------------------------
do $$
declare r record; f record;
begin
  -- method-default fee: zone B has no rule for tv_deliv
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000b2', 200000);
  perform pg_temp.ok(r.is_valid and r.fee_cents = 25000 and r.fee_source = 'method'
    and r.zone_fee_id is null, 'method-default delivery fee (no zone rule)');

  -- zone-specific fee
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000);
  perform pg_temp.ok(r.is_valid and r.fee_cents = 40000 and r.fee_source = 'zone'
    and r.zone_fee_id = '00000000-0000-4000-8000-0000000000f1',
    'zone-specific delivery fee replaces the method fee');

  -- free-delivery threshold, method level (zone B)
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000b2', 500000);
  perform pg_temp.ok(r.is_valid and r.fee_cents = 0 and r.base_fee_cents = 25000,
    'free-delivery threshold waives the method fee at exactly the threshold');
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000b2', 499999);
  perform pg_temp.ok(r.fee_cents = 25000, 'one cent below the free threshold still pays the fee');

  -- free-delivery threshold, zone level overrides the method's 500000
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 600000);
  perform pg_temp.ok(r.fee_cents = 40000, 'zone rule threshold (800000) overrides the method threshold');
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 800000);
  perform pg_temp.ok(r.fee_cents = 0, 'zone free-delivery threshold waives the zone fee');

  -- the zone minimum can only raise the method minimum
  select * into r from public.validate_delivery_selection(
    'tv_minm', '00000000-0000-4000-8000-0000000000a1', 99999);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'below_minimum_order' and r.min_order_cents = 100000,
    'a zone rule with a lower minimum does not lower the method minimum');
  select * into r from public.validate_delivery_selection(
    'tv_minm', '00000000-0000-4000-8000-0000000000a1', 100000);
  perform pg_temp.ok(r.is_valid and r.fee_cents = 5000, 'method minimum met, zone fee applied');

  -- fee_rule is the snapshot shape stored on orders
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000);
  perform pg_temp.ok(
    r.fee_rule ->> 'source' = 'zone'
    and (r.fee_rule ->> 'base_fee_cents')::int = 40000
    and (r.fee_rule ->> 'free_over_cents')::int = 800000
    and (r.fee_rule ->> 'min_order_cents')::int = 150000
    and r.fee_rule ->> 'zone_fee_id' = '00000000-0000-4000-8000-0000000000f1',
    'fee_rule jsonb matches the order snapshot shape');

  -- authority: identical to the single fee calculation, for every case above
  select * into f from public.resolve_delivery_fee(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000);
  perform pg_temp.ok(f.fee_cents = r.fee_cents and f.fee_source = r.fee_source
    and f.min_order_cents = r.min_order_cents, 'validate_delivery_selection agrees with resolve_delivery_fee');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Client cannot influence the fee
-- ---------------------------------------------------------------------------
do $$
declare
  v_in_args integer;
  v_names text[];
  v_threw boolean := false;
  r record;
begin
  select p.pronargs, p.proargnames into v_in_args, v_names
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'validate_delivery_selection';
  perform pg_temp.ok(v_in_args = 3, 'validate_delivery_selection accepts exactly three inputs');
  perform pg_temp.ok(not exists (
      -- Match fee/total as whole name tokens (p_fee_cents, p_total_cents, p_order_total...).
      -- A plain substring match would wrongly reject the legitimate p_subtotal_cents input.
      select 1 from unnest(v_names[1:3]) as a
      where a ~* '(^|_)(fee|fees|total|grand_total)(_|$)'),
    'no input argument can carry a fee or total');
  perform pg_temp.ok(v_names[1:3] = array['p_method_code','p_zone_id','p_subtotal_cents'],
    'the three inputs are exactly method, zone and subtotal');

  begin
    execute $q$select * from public.validate_delivery_selection(
      'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000, 0)$q$;
  exception when undefined_function then
    v_threw := true;
  end;
  perform pg_temp.ok(v_threw, 'passing an extra (fee) argument is rejected, not honoured');

  -- A customer-visible session gets the same database fee, not anything it asked for.
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000c001', true);
  set local role authenticated;
  select * into r from public.validate_delivery_selection(
    'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000);
  reset role;
  perform pg_temp.ok(r.is_valid and r.fee_cents = 40000,
    'a customer session receives the database fee (40000)');

  -- ...and cannot write a fee onto an order (column is not granted to the browser role).
  v_threw := false;
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}', true);
  set local role authenticated;
  begin
    update public.orders set delivery_fee_cents = 0 where false;
  exception when insufficient_privilege then
    v_threw := true;
  end;
  reset role;
  perform pg_temp.ok(v_threw, 'customer cannot update orders.delivery_fee_cents');

  -- inactive and unknown stay distinguishable even though a customer cannot read inactive rows
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}', true);
  set local role authenticated;
  select * into r from public.validate_delivery_selection(
    'tv_off', '00000000-0000-4000-8000-0000000000a1', 900000);
  reset role;
  perform pg_temp.ok(r.error_code = 'method_inactive', 'customer session still gets method_inactive');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Authorisation preserved: customers cannot change configuration
--
-- Checks are recorded while the session role is `authenticated` and asserted after
-- `reset role`, because a browser role has no business calling pg_temp helpers.
-- ---------------------------------------------------------------------------
do $$
declare
  n integer;
  v_threw boolean;
  v_names text[] := '{}';
  v_pass boolean[] := '{}';
  i integer;
begin
  insert into public.delivery_slot_templates (id, label, start_time, end_time)
  values ('00000000-0000-4000-8000-0000000000d1', 'TV slot', '09:00', '11:00');

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000c001', true);
  set local role authenticated;

  -- UPDATEs that RLS filters out match zero rows
  update public.delivery_zone_fees set fee_cents = 1
    where id = '00000000-0000-4000-8000-0000000000f1';
  get diagnostics n = row_count;
  v_names := v_names || 'customer cannot update zone fees'::text; v_pass := v_pass || (n = 0);

  update public.delivery_zones set is_active = false
    where id = '00000000-0000-4000-8000-0000000000a1';
  get diagnostics n = row_count;
  v_names := v_names || 'customer cannot update zones'::text; v_pass := v_pass || (n = 0);

  update public.delivery_methods set base_fee_cents = 0 where code = 'tv_deliv';
  get diagnostics n = row_count;
  v_names := v_names || 'customer cannot update delivery methods'::text; v_pass := v_pass || (n = 0);

  update public.delivery_slot_templates set capacity = 999
    where id = '00000000-0000-4000-8000-0000000000d1';
  get diagnostics n = row_count;
  v_names := v_names || 'customer cannot update slot templates / capacity'::text; v_pass := v_pass || (n = 0);

  -- INSERTs are refused outright
  v_threw := false;
  begin
    insert into public.delivery_zones (code, name) values ('tv-evil', 'Evil');
  exception when insufficient_privilege then v_threw := true; end;
  v_names := v_names || 'customer cannot insert zones'::text; v_pass := v_pass || v_threw;

  v_threw := false;
  begin
    insert into public.delivery_zone_fees (zone_id, method_code, fee_cents)
    values ('00000000-0000-4000-8000-0000000000b2', 'tv_deliv', 0);
  exception when insufficient_privilege then v_threw := true; end;
  v_names := v_names || 'customer cannot insert zone fees'::text; v_pass := v_pass || v_threw;

  v_threw := false;
  begin
    insert into public.delivery_methods (code, label) values ('tv_evil', 'Evil');
  exception when insufficient_privilege then v_threw := true; end;
  v_names := v_names || 'customer cannot insert delivery methods'::text; v_pass := v_pass || v_threw;

  v_threw := false;
  begin
    insert into public.delivery_slot_overrides (template_id, slot_date, capacity)
    values ('00000000-0000-4000-8000-0000000000d1', current_date, 1000);
  exception when insufficient_privilege then v_threw := true; end;
  v_names := v_names || 'customer cannot insert slot overrides'::text; v_pass := v_pass || v_threw;

  reset role;

  for i in 1 .. coalesce(array_length(v_names, 1), 0) loop
    perform pg_temp.ok(v_pass[i], v_names[i]);
  end loop;

  -- Nothing was changed behind the scenes
  perform pg_temp.ok(
    (select fee_cents from public.delivery_zone_fees where id = '00000000-0000-4000-8000-0000000000f1') = 40000
    and (select base_fee_cents from public.delivery_methods where code = 'tv_deliv') = 25000
    and (select capacity from public.delivery_slot_templates
         where id = '00000000-0000-4000-8000-0000000000d1') is null,
    'configuration is unchanged after the customer attempts');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Authorisation preserved: staff and admin can change configuration
-- ---------------------------------------------------------------------------
do $$
declare
  n integer;
  v_user text;
  v_day integer := 0;
  v_names text[] := '{}';
  v_pass boolean[] := '{}';
  i integer;
begin
  foreach v_user in array array[
    '00000000-0000-4000-8000-00000000c002',   -- staff
    '00000000-0000-4000-8000-00000000c003'    -- admin
  ] loop
    v_day := v_day + 1;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_user, true);
    set local role authenticated;

    update public.delivery_zone_fees set fee_cents = 41000
      where id = '00000000-0000-4000-8000-0000000000f1';
    get diagnostics n = row_count;
    v_names := v_names || format('%s can update zone fees', v_user); v_pass := v_pass || (n = 1);

    update public.delivery_zones set description = 'staff edit'
      where id = '00000000-0000-4000-8000-0000000000b2';
    get diagnostics n = row_count;
    v_names := v_names || format('%s can update zones', v_user); v_pass := v_pass || (n = 1);

    update public.delivery_methods set eta_label = 'staff edit' where code = 'tv_deliv';
    get diagnostics n = row_count;
    v_names := v_names || format('%s can update delivery methods', v_user); v_pass := v_pass || (n = 1);

    update public.delivery_slot_templates set capacity = 5
      where id = '00000000-0000-4000-8000-0000000000d1';
    get diagnostics n = row_count;
    v_names := v_names || format('%s can update slot capacity', v_user); v_pass := v_pass || (n = 1);

    insert into public.delivery_slot_overrides (template_id, slot_date, capacity)
    values ('00000000-0000-4000-8000-0000000000d1', current_date + v_day, 3);
    get diagnostics n = row_count;
    v_names := v_names || format('%s can insert slot overrides', v_user); v_pass := v_pass || (n = 1);

    -- staff can read inactive configuration that customers cannot
    v_names := v_names || format('%s can read inactive zones', v_user);
    v_pass := v_pass || exists (
      select 1 from public.delivery_zones where id = '00000000-0000-4000-8000-0000000000c3');

    reset role;
  end loop;

  for i in 1 .. coalesce(array_length(v_names, 1), 0) loop
    perform pg_temp.ok(v_pass[i], v_names[i]);
  end loop;

  -- and a staff edit is what validation then uses (single source of truth)
  perform pg_temp.ok(
    (select fee_cents from public.validate_delivery_selection(
       'tv_deliv', '00000000-0000-4000-8000-0000000000a1', 200000)) = 41000,
    'validation reflects the staff-edited zone fee');
end $$;

do $$ begin raise notice 'ALL DELIVERY VALIDATION TESTS PASSED'; end $$;

rollback;
