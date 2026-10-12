-- =============================================================================
-- PHASE 8 database test: discounts & promotions.
--
-- STATUS: written for migration 20261009010000_phase8_discounts_promotions.sql.
-- NOT RUN against any database when it was written (no PostgreSQL was available); see the report.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261009010000_phase8_discounts_promotions.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase8_discounts_promotions.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 8 TESTS PASSED" means all passed.
--
-- DATABASE-DATA NOTE: the test may run on a database holding real data. It deactivates every
-- AUTOMATIC promotion inside its own transaction (so none can leak into the fixtures) and rolls
-- that back too. All fixture codes start with P8-.
--
-- WHAT THIS PROVES, and what it cannot: one session proves the RULES, the stored snapshot,
-- rollback of failed orders, release/re-take on cancel/reactivate, privileges and RLS. It cannot
-- prove the row lock holds against a REAL race: that is db/tests/phase8_coupon_concurrency.sh
-- (also not run). The lock is asserted structurally by the migration's self-check.
--
-- COVERS
--   1 rules (percent floor, cap, fixed, never above base)   2 delivery not discountable, total >= fee
--   3 minimum order (boundary)                              4 expiry / not-started (boundaries, injected clock)
--   5 invalid / inactive / malformed are indistinguishable  6 global limit + release on cancel + reactivation refusal
--   7 per-customer limit                                    8 one redemption per order; idempotent replay
--   9 snapshot immutability (promotion edits, direct UPDATE)  10 automatic promotions, best wins, code overrides
--  11 failed order consumes nothing                         12 expected-total veto includes the discount
--  13 privileges / RLS / validate_coupon                    14 admin guard, validation, audit, deactivate
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

-- No automatic promotion from real data may touch the fixtures (rolled back at the end).
update public.promotions set is_active = false where code is null;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-000000000801', 'p8-u1@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-000000000802', 'p8-u2@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000008ad', 'p8-admin@example.test', 'authenticated', 'authenticated');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000008ad', 'admin');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-0000000008b1', 'p8-product', 'P8 product', 10000, 1000, true, true);

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('p8_free', 'P8 pickup, free',    0,    null, 0, false, false, true),
  ('p8_fee',  'P8 pickup, fee 5000', 5000, null, 0, false, false, true);

-- Coupons (inserted as the owner; customers can never do this).
insert into public.promotions
  (id, code, name, discount_type, value, max_discount_cents, min_order_cents, starts_at, expires_at,
   usage_limit, per_customer_limit, is_active)
values
  ('00000000-0000-4000-8000-0000000008c1', 'P8-TEN',    'Ten percent',   'percentage', 1000,  null, 0,     null, null, null, null, true),
  ('00000000-0000-4000-8000-0000000008c2', 'P8-FIXBIG', 'Fixed huge',    'fixed',      99999, null, 0,     null, null, null, null, true),
  ('00000000-0000-4000-8000-0000000008c3', 'P8-CAP',    'Half, capped',  'percentage', 5000,  1500, 0,     null, null, null, null, true),
  ('00000000-0000-4000-8000-0000000008c4', 'P8-MIN',    'Fixed with min','fixed',      500,   null, 20000, null, null, null, null, true),
  ('00000000-0000-4000-8000-0000000008c5', 'P8-EXP',    'Expired',       'percentage', 1000,  null, 0, now() - interval '2 hours', now() - interval '1 hour', null, null, true),
  ('00000000-0000-4000-8000-0000000008c6', 'P8-FUT',    'Future',        'percentage', 1000,  null, 0, now() + interval '1 hour', null, null, null, true),
  ('00000000-0000-4000-8000-0000000008c7', 'P8-OFF',    'Inactive',      'percentage', 1000,  null, 0, null, null, null, null, false),
  ('00000000-0000-4000-8000-0000000008c8', 'P8-LIM',    'Global limit 2','fixed',      100,   null, 0, null, null, 2,    null, true),
  ('00000000-0000-4000-8000-0000000008c9', 'P8-PER',    'Once each',     'fixed',      100,   null, 0, null, null, null, 1,    true),
  ('00000000-0000-4000-8000-0000000008ca', 'P8-ONE',    'Single use',    'fixed',      100,   null, 0, null, null, 1,    null, true),
  ('00000000-0000-4000-8000-0000000008cb', 'P8-BND',    'Boundaries',    'percentage', 1000,  null, 0,
     timestamptz '2030-01-01 00:00:00+00', timestamptz '2030-01-02 00:00:00+00', null, null, true);

-- try_order(): create_order() inside a sub-transaction as a given customer. Always one row.
create or replace function pg_temp.try_order(
  p_user uuid, p_code text default null, p_qty integer default 1, p_method text default 'p8_free',
  p_key text default null, p_expected integer default null
) returns table (order_id uuid, msg text, code text)
language plpgsql as $$
declare v_id uuid; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  begin
    v_id := public.create_order(
      jsonb_build_array(jsonb_build_object(
        'product_id', '00000000-0000-4000-8000-0000000008b1', 'variant_id', null, 'quantity', p_qty)),
      p_method, 'cash_on_delivery', null, null, null, null, null, null, p_key, p_expected, null, p_code);
    return query select v_id, null::text, null::text;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    return query select null::uuid, v_msg, v_detail;
  end;
end;
$$;

create or replace function pg_temp.u1() returns uuid language sql as $$ select '00000000-0000-4000-8000-000000000801'::uuid $$;
create or replace function pg_temp.u2() returns uuid language sql as $$ select '00000000-0000-4000-8000-000000000802'::uuid $$;

create temp table t_ord (k text primary key, order_id uuid, msg text, code text);
create or replace function pg_temp.place(p_k text, p_user uuid, p_code text default null, p_qty integer default 1,
  p_method text default 'p8_free', p_key text default null, p_expected integer default null)
returns void language plpgsql as $$
begin
  insert into t_ord select p_k, o.order_id, o.msg, o.code
    from pg_temp.try_order(p_user, p_code, p_qty, p_method, p_key, p_expected) o
  on conflict (k) do update set order_id = excluded.order_id, msg = excluded.msg, code = excluded.code;
end;
$$;
create or replace function pg_temp.ord_id(p_k text) returns uuid language sql as $$ select order_id from t_ord where k = p_k $$;
create or replace function pg_temp.ocode(p_k text) returns text language sql as $$ select code from t_ord where k = p_k $$;
create or replace function pg_temp.omsg(p_k text) returns text language sql as $$ select msg from t_ord where k = p_k $$;

-- ---------------------------------------------------------------------------
-- 0. Shape
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok((select count(*) from pg_proc where proname = 'create_order'
    and pronamespace = 'public'::regnamespace) = 1, 'exactly one create_order() overload');
  perform pg_temp.ok((select pronargs from pg_proc where proname = 'create_order'
    and pronamespace = 'public'::regnamespace) = 13, 'create_order() takes 13 arguments');
  perform pg_temp.ok(not exists (
    select 1 from pg_proc p, unnest(p.proargnames) n
     where p.proname = 'create_order' and p.pronamespace = 'public'::regnamespace
       and (n ilike '%discount%' or n ilike '%fee%' or n ilike '%subtotal%' or n ilike '%amount%')),
    'no create_order() argument can carry a discount, fee, subtotal or amount (only a code)');
end $$;

-- ---------------------------------------------------------------------------
-- 1. Rules
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok(public.compute_promotion_discount('percentage', 1000, null, 10000) = 1000, 'percentage 10% of 10000 = 1000');
  perform pg_temp.ok(public.compute_promotion_discount('percentage', 3333, null, 100) = 33, 'percentage floors (33.33 -> 33)');
  perform pg_temp.ok(public.compute_promotion_discount('percentage', 1, null, 9999) = 0, 'a tiny percentage can floor to 0');
  perform pg_temp.ok(public.compute_promotion_discount('percentage', 5000, 1500, 10000) = 1500, 'cap applies to a percentage');
  perform pg_temp.ok(public.compute_promotion_discount('percentage', 10000, null, 777) = 777, '100% = the whole base, no more');
  perform pg_temp.ok(public.compute_promotion_discount('fixed', 300, null, 10000) = 300, 'fixed amount');
  perform pg_temp.ok(public.compute_promotion_discount('fixed', 50000, null, 10000) = 10000, 'fixed never exceeds the base');
  perform pg_temp.ok(public.compute_promotion_discount('fixed', 300, null, 0) = 0, 'empty base gives 0');
  perform pg_temp.ok(public.coupon_eligible_base_cents(10000, 5000) = 10000, 'eligible base excludes delivery');
end $$;

-- ---------------------------------------------------------------------------
-- 2. A plain coupon, with a delivery fee
-- ---------------------------------------------------------------------------
select pg_temp.place('ten', pg_temp.u1(), 'p8-ten', 1, 'p8_fee');   -- lower-case on purpose: normalised
do $$
declare o public.orders; r public.promotion_redemptions;
begin
  select * into o from public.orders where id = pg_temp.ord_id('ten');
  perform pg_temp.ok(o.id is not null, 'order with a coupon was created (' || coalesce(pg_temp.omsg('ten'), 'ok') || ')');
  perform pg_temp.ok(o.subtotal_cents = 10000 and o.delivery_fee_cents = 5000 and o.discount_cents = 1000
                     and o.total_cents = 14000, 'subtotal 10000 + fee 5000 - discount 1000 = 14000');
  perform pg_temp.ok(o.discount_code = 'P8-TEN' and o.discount_name = 'Ten percent' and o.discount_type = 'percentage'
                     and o.discount_value = 1000 and o.discount_applied_at is not null
                     and o.discount_promotion_id = '00000000-0000-4000-8000-0000000008c1', 'snapshot columns are filled');
  select * into r from public.promotion_redemptions where order_id = o.id;
  perform pg_temp.ok(r.amount_cents = 1000 and r.released_at is null and r.user_id = pg_temp.u1(), 'one active redemption for the order');
end $$;

-- Delivery is not discountable; the total never drops below the fee nor below zero.
select pg_temp.place('big', pg_temp.u1(), 'P8-FIXBIG', 1, 'p8_fee');
select pg_temp.place('cap', pg_temp.u1(), 'P8-CAP', 1, 'p8_fee');
do $$
declare o public.orders;
begin
  select * into o from public.orders where id = pg_temp.ord_id('big');
  perform pg_temp.ok(o.discount_cents = 10000 and o.total_cents = 5000 and o.total_cents >= o.delivery_fee_cents,
    'a huge fixed coupon takes the whole subtotal but never the delivery fee (total 5000)');
  select * into o from public.orders where id = pg_temp.ord_id('cap');
  perform pg_temp.ok(o.discount_cents = 1500 and o.total_cents = 13500, 'cap: 50% of 10000 capped at 1500');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Minimum order (merchandise subtotal, boundary inclusive)
-- ---------------------------------------------------------------------------
select pg_temp.place('min1', pg_temp.u1(), 'P8-MIN', 1, 'p8_fee');
select pg_temp.place('min2', pg_temp.u1(), 'P8-MIN', 2, 'p8_fee');
do $$
begin
  perform pg_temp.ok(pg_temp.ocode('min1') = 'coupon_min_not_met', 'below the minimum: coupon_min_not_met even though delivery would lift the total');
  perform pg_temp.ok(pg_temp.ord_id('min2') is not null
    and (select discount_cents from public.orders where id = pg_temp.ord_id('min2')) = 500, 'exactly at the minimum (20000) applies');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Time window (real clock, then an injected clock for the exact boundaries)
-- ---------------------------------------------------------------------------
select pg_temp.place('exp', pg_temp.u1(), 'P8-EXP');
select pg_temp.place('fut', pg_temp.u1(), 'P8-FUT');
do $$
declare s timestamptz := timestamptz '2030-01-01 00:00:00+00'; e timestamptz := timestamptz '2030-01-02 00:00:00+00';
begin
  perform pg_temp.ok(pg_temp.ocode('exp') = 'coupon_expired', 'expired coupon: coupon_expired');
  perform pg_temp.ok(pg_temp.ocode('fut') = 'coupon_not_started', 'future coupon: coupon_not_started');
  perform pg_temp.ok((select error_code from public.resolve_promotion('P8-BND', pg_temp.u1(), 10000, 0, false, s - interval '1 microsecond')) = 'not_started', 'one microsecond before the start: not_started');
  perform pg_temp.ok((select error_code from public.resolve_promotion('P8-BND', pg_temp.u1(), 10000, 0, false, s)) is null, 'at the start instant: valid');
  perform pg_temp.ok((select error_code from public.resolve_promotion('P8-BND', pg_temp.u1(), 10000, 0, false, e - interval '1 microsecond')) is null, 'one microsecond before expiry: valid');
  perform pg_temp.ok((select error_code from public.resolve_promotion('P8-BND', pg_temp.u1(), 10000, 0, false, e)) = 'expired', 'at the expiry instant: expired');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Unknown, inactive and malformed codes are indistinguishable
-- ---------------------------------------------------------------------------
select pg_temp.place('unk', pg_temp.u1(), 'P8-NOPE');
select pg_temp.place('off', pg_temp.u1(), 'P8-OFF');
select pg_temp.place('bad', pg_temp.u1(), 'a b!');
do $$
begin
  perform pg_temp.ok(pg_temp.ocode('unk') = 'coupon_invalid' and pg_temp.ocode('off') = 'coupon_invalid' and pg_temp.ocode('bad') = 'coupon_invalid',
    'unknown, inactive and malformed all give coupon_invalid');
  perform pg_temp.ok(pg_temp.omsg('unk') = pg_temp.omsg('off') and pg_temp.omsg('off') = pg_temp.omsg('bad'),
    'and the message is identical (nothing leaks about which codes exist)');
  perform pg_temp.ok(pg_temp.omsg('unk') !~* 'P8-|inactive|exist|limit', 'the message names no code and no reason');
  perform pg_temp.ok(not exists (select 1 from public.orders where id in (pg_temp.ord_id('unk'), pg_temp.ord_id('off'), pg_temp.ord_id('bad'))),
    'a refused coupon creates no order');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Global limit, release on cancel, refusal to reactivate over the limit
-- ---------------------------------------------------------------------------
select pg_temp.place('lim1', pg_temp.u1(), 'P8-LIM');
select pg_temp.place('lim2', pg_temp.u2(), 'P8-LIM');
select pg_temp.place('lim3', pg_temp.u1(), 'P8-LIM');
do $$
begin
  perform pg_temp.ok(pg_temp.ord_id('lim1') is not null and pg_temp.ord_id('lim2') is not null, 'the first two uses of a 2-use coupon succeed');
  perform pg_temp.ok(pg_temp.ocode('lim3') = 'coupon_limit_reached', 'the third use: coupon_limit_reached');
end $$;

update public.orders set status = 'cancelled' where id = pg_temp.ord_id('lim1');
do $$
declare r public.promotion_redemptions;
begin
  select * into r from public.promotion_redemptions where order_id = pg_temp.ord_id('lim1');
  perform pg_temp.ok(r.released_at is not null and r.release_reason = 'order_cancelled', 'cancelling an order releases its redemption');
end $$;
select pg_temp.place('lim4', pg_temp.u1(), 'P8-LIM');
do $$
begin
  perform pg_temp.ok(pg_temp.ord_id('lim4') is not null, 'a released use can be taken by a new order');
end $$;
do $$
declare v_detail text; v_status text;
begin
  begin
    update public.orders set status = 'pending' where id = pg_temp.ord_id('lim1');
    v_detail := 'no error';
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  select status::text into v_status from public.orders where id = pg_temp.ord_id('lim1');
  perform pg_temp.ok(v_detail = 'coupon_reactivation_limit_reached' and v_status = 'cancelled',
    'reactivating over the limit is refused and the order stays cancelled [' || coalesce(v_detail, '-') || ']');
end $$;
-- Free a use, then the reactivation is allowed and the use is taken again.
update public.orders set status = 'cancelled' where id = pg_temp.ord_id('lim4');
update public.orders set status = 'pending' where id = pg_temp.ord_id('lim1');
do $$
begin
  perform pg_temp.ok((select released_at from public.promotion_redemptions where order_id = pg_temp.ord_id('lim1')) is null,
    'reactivation within the limit re-takes the use');
  perform pg_temp.ok((select count(*) from public.promotion_redemptions r
    where r.promotion_id = '00000000-0000-4000-8000-0000000008c8' and r.released_at is null) = 2, 'active uses never exceed the limit (2)');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Per-customer limit
-- ---------------------------------------------------------------------------
select pg_temp.place('per1', pg_temp.u1(), 'P8-PER');
select pg_temp.place('per2', pg_temp.u1(), 'P8-PER');
select pg_temp.place('per3', pg_temp.u2(), 'P8-PER');
do $$
begin
  perform pg_temp.ok(pg_temp.ord_id('per1') is not null, 'first use by customer 1');
  perform pg_temp.ok(pg_temp.ocode('per2') = 'coupon_already_used', 'second use by customer 1: coupon_already_used');
  perform pg_temp.ok(pg_temp.ord_id('per3') is not null, 'customer 2 is unaffected');
end $$;

-- ---------------------------------------------------------------------------
-- 8. One redemption per order; idempotent replay
-- ---------------------------------------------------------------------------
select pg_temp.place('idem1', pg_temp.u2(), 'P8-TEN', 1, 'p8_free', 'p8-idem-key');
select pg_temp.place('idem2', pg_temp.u2(), 'P8-TEN', 1, 'p8_free', 'p8-idem-key');
do $$
declare v_detail text;
begin
  perform pg_temp.ok(pg_temp.ord_id('idem1') is not null and pg_temp.ord_id('idem1') = pg_temp.ord_id('idem2'), 'replaying the same checkout returns the same order');
  perform pg_temp.ok((select count(*) from public.promotion_redemptions where order_id = pg_temp.ord_id('idem1')) = 1, 'and still exactly one redemption');
  begin
    insert into public.promotion_redemptions (promotion_id, order_id, user_id, amount_cents)
    values ('00000000-0000-4000-8000-0000000008c1', pg_temp.ord_id('idem1'), pg_temp.u2(), 1);
    v_detail := 'no error';
  exception when unique_violation then v_detail := 'unique_violation';
  end;
  perform pg_temp.ok(v_detail = 'unique_violation', 'UNIQUE (order_id): a second redemption on the same order is impossible');
end $$;

-- ---------------------------------------------------------------------------
-- 9. Snapshot immutability
-- ---------------------------------------------------------------------------
do $$
declare before_row record; after_row record; v_detail text;
begin
  select discount_cents, discount_code, discount_name, discount_type, discount_value, total_cents
    into before_row from public.orders where id = pg_temp.ord_id('ten');

  update public.promotions set value = 5000, name = 'Renamed', code = 'P8-RENAMED', is_active = false
   where id = '00000000-0000-4000-8000-0000000008c1';

  select discount_cents, discount_code, discount_name, discount_type, discount_value, total_cents
    into after_row from public.orders where id = pg_temp.ord_id('ten');
  perform pg_temp.ok(before_row = after_row, 'editing and deactivating a promotion does not change a past order');

  begin
    update public.orders set discount_cents = 0, total_cents = total_cents + discount_cents where id = pg_temp.ord_id('ten');
    v_detail := 'no error';
  exception when others then get stacked diagnostics v_detail = pg_exception_detail;
  end;
  perform pg_temp.ok(v_detail = 'discount_snapshot_immutable', 'direct UPDATE of discount_cents is refused [' || coalesce(v_detail, '-') || ']');

  begin
    update public.orders set discount_code = 'HACK' where id = pg_temp.ord_id('ten');
    v_detail := 'no error';
  exception when others then get stacked diagnostics v_detail = pg_exception_detail;
  end;
  perform pg_temp.ok(v_detail = 'discount_snapshot_immutable', 'direct UPDATE of the snapshot code is refused');

  begin
    update public.promotion_redemptions set amount_cents = 1 where order_id = pg_temp.ord_id('ten');
    v_detail := 'no error';
  exception when others then get stacked diagnostics v_detail = pg_exception_detail;
  end;
  perform pg_temp.ok(v_detail = 'redemption_immutable', 'a redemption amount cannot be rewritten');

  -- restore for later sections
  update public.promotions set value = 1000, name = 'Ten percent', code = 'P8-TEN', is_active = true
   where id = '00000000-0000-4000-8000-0000000008c1';
end $$;

-- ---------------------------------------------------------------------------
-- 10. Automatic promotions (best wins; an explicit code overrides; unqualified ones are skipped)
-- ---------------------------------------------------------------------------
insert into public.promotions (id, code, name, discount_type, value, min_order_cents, is_active) values
  ('00000000-0000-4000-8000-0000000008d1', null, 'Auto 5%',           'percentage', 500,  0,     true),
  ('00000000-0000-4000-8000-0000000008d2', null, 'Auto fixed 700',    'fixed',      700,  0,     true),
  ('00000000-0000-4000-8000-0000000008d3', null, 'Auto 50% over 1M',  'percentage', 5000, 1000000, true);
select pg_temp.place('auto', pg_temp.u1());                       -- no code
select pg_temp.place('autocode', pg_temp.u1(), 'P8-CAP');         -- code beats automatic
do $$
declare o public.orders;
begin
  select * into o from public.orders where id = pg_temp.ord_id('auto');
  perform pg_temp.ok(o.discount_cents = 700 and o.discount_code is null and o.discount_name = 'Auto fixed 700',
    'no code: the best qualifying automatic promotion applies (700 beats 5% = 500; the 1M minimum one is skipped)');
  select * into o from public.orders where id = pg_temp.ord_id('autocode');
  perform pg_temp.ok(o.discount_code = 'P8-CAP' and o.discount_cents = 1500, 'an explicit code applies instead of any automatic promotion (no stacking)');
  perform pg_temp.ok((select count(*) from public.promotion_redemptions where order_id in (o.id, pg_temp.ord_id('auto'))) = 2, 'each order holds exactly one redemption');
end $$;
update public.promotions set is_active = false where code is null;   -- keep later sections clean

-- ---------------------------------------------------------------------------
-- 11. A failed order consumes nothing (the coupon transaction rolls back with it)
-- ---------------------------------------------------------------------------
select pg_temp.place('veto', pg_temp.u1(), 'P8-ONE', 1, 'p8_free', null, 123);     -- wrong expected total
select pg_temp.place('after', pg_temp.u2(), 'P8-ONE', 1, 'p8_free', null, 9900);   -- correct: 10000 - 100
do $$
begin
  perform pg_temp.ok(pg_temp.ord_id('veto') is null and pg_temp.omsg('veto') like 'Prices or delivery fees have changed%', 'a wrong expected total refuses the order');
  perform pg_temp.ok(pg_temp.ord_id('after') is not null, 'the single-use coupon was NOT consumed by the failed order, and the expected total INCLUDES the discount (9900)');
  perform pg_temp.ok((select count(*) from public.promotion_redemptions where promotion_id = '00000000-0000-4000-8000-0000000008ca') = 1, 'exactly one redemption exists for the single-use coupon');
end $$;

-- ---------------------------------------------------------------------------
-- 12/13. Privileges, RLS and validate_coupon (as the real API roles)
-- ---------------------------------------------------------------------------
create temp table t_res (k text primary key, res text, err text, state text, detail text);
create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claim.role', case when p_uid is null then '' else p_role end, true);
  begin
    execute format('set local role %I', p_role);
    execute p_sql into v_res;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_res values (p_k, v_res, v_err, v_state, nullif(v_detail, ''))
  on conflict (k) do update set res = excluded.res, err = excluded.err, state = excluded.state, detail = excluded.detail;
end;
$$;
create or replace function pg_temp.denied(p_k text) returns boolean language sql as $$
  select err is not null and state = '42501' and res is null from t_res where k = p_k $$;

select pg_temp.run('anon_promos',  'anon',          null,           'select count(*)::text from public.promotions');
select pg_temp.run('cust_promos',  'authenticated', pg_temp.u1(),   'select count(*)::text from public.promotions');
select pg_temp.run('svc_promos',   'service_role',  null,           'select count(*)::text from public.promotions');
select pg_temp.run('cust_redeem',  'authenticated', pg_temp.u1(),   'select count(*)::text from public.promotion_redemptions');
select pg_temp.run('cust_insert',  'authenticated', pg_temp.u1(),   $q$insert into public.promotions (name, discount_type, value) values ('x','fixed',1)$q$);
select pg_temp.run('anon_validate','anon',          null,
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'P8-TEN')::text$q$);
select pg_temp.run('v_ok',        'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'p8-cap')::text$q$);
select pg_temp.run('v_unknown',   'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'P8-NOPE')::text$q$);
select pg_temp.run('v_expired',   'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'P8-EXP')::text$q$);
select pg_temp.run('v_per',       'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'P8-PER')::text$q$);
select pg_temp.run('v_none',      'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb)::text$q$);
select pg_temp.run('v_badcart',   'authenticated', pg_temp.u1(),
  $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008ff","variant_id":null,"quantity":1}]'::jsonb, 'P8-CAP')::text$q$);
select pg_temp.run('own_snap',    'authenticated', pg_temp.u1(),
  format($q$select discount_code from public.orders where id = %L$q$, pg_temp.ord_id('cap')));
select pg_temp.run('other_snap',  'authenticated', pg_temp.u2(),
  format($q$select count(*)::text from public.orders where id = %L$q$, pg_temp.ord_id('cap')));
do $$
begin
  perform pg_temp.ok(pg_temp.denied('anon_promos') and pg_temp.denied('cust_promos') and pg_temp.denied('svc_promos'),
    'anon, customers and service_role cannot read the promotions table');
  perform pg_temp.ok(pg_temp.denied('cust_redeem'), 'customers cannot read promotion_redemptions');
  perform pg_temp.ok(pg_temp.denied('cust_insert'), 'customers cannot insert a promotion');
  perform pg_temp.ok(pg_temp.denied('anon_validate'), 'anon cannot call validate_coupon');
  perform pg_temp.ok((select (res::jsonb) = jsonb_build_object('ok', true, 'applied', true, 'code', 'P8-CAP', 'name', 'Half, capped',
      'discount_type', 'percentage', 'discount_value', 5000, 'discount_cents', 1500, 'subtotal_cents', 10000, 'eligible_cents', 10000)
      from t_res where k = 'v_ok'), 'validate_coupon prices the basket from the database and returns the capped discount');
  perform pg_temp.ok((select res::jsonb from t_res where k = 'v_unknown') = '{"ok": false, "error": "invalid"}'::jsonb, 'validate_coupon: unknown -> invalid');
  perform pg_temp.ok((select res::jsonb from t_res where k = 'v_expired') = '{"ok": false, "error": "expired"}'::jsonb, 'validate_coupon: expired');
  perform pg_temp.ok((select res::jsonb from t_res where k = 'v_per') = '{"ok": false, "error": "already_used"}'::jsonb, 'validate_coupon: already_used for the customer who used it');
  perform pg_temp.ok((select (res::jsonb ->> 'applied') = 'false' and (res::jsonb ->> 'ok') = 'true' from t_res where k = 'v_none'), 'validate_coupon with no code and no automatic promotion: nothing applies');
  perform pg_temp.ok((select err is not null and detail = 'invalid_cart' from t_res where k = 'v_badcart'), 'validate_coupon refuses a basket with an unknown product (invalid_cart)');
  perform pg_temp.ok((select res from t_res where k = 'own_snap') = 'P8-CAP', 'a customer reads the discount snapshot on their own order');
  perform pg_temp.ok((select res from t_res where k = 'other_snap') = '0', 'and not on someone else''s');
end $$;

-- ---------------------------------------------------------------------------
-- 14. Admin guard, validation, audit, deactivation
-- ---------------------------------------------------------------------------
select pg_temp.run('a_create', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"code":" p8-admin1 ","name":"Admin made","discount_type":"fixed","value":250,"usage_limit":5}'::jsonb)::text$q$);
select pg_temp.run('a_dup', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"code":"P8-ADMIN1","name":"Dup","discount_type":"fixed","value":1}'::jsonb)::text$q$);
select pg_temp.run('a_bad1', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"name":"Bad","discount_type":"percentage","value":10001}'::jsonb)::text$q$);
select pg_temp.run('a_bad2', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"name":"Bad","discount_type":"fixed","value":5,"max_discount_cents":10}'::jsonb)::text$q$);
select pg_temp.run('a_bad3', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"name":"Bad","discount_type":"fixed","value":5,"starts_at":"2030-01-02","expires_at":"2030-01-01"}'::jsonb)::text$q$);
select pg_temp.run('a_bad4', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"code":"lower case","name":"Bad","discount_type":"fixed","value":5}'::jsonb)::text$q$);
select pg_temp.run('a_unknown', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
  $q$select public.admin_create_promotion('{"name":"x","discount_type":"fixed","value":5,"redeemed":99}'::jsonb)::text$q$);
select pg_temp.run('c_create', 'authenticated', pg_temp.u1(),
  $q$select public.admin_create_promotion('{"name":"x","discount_type":"fixed","value":5}'::jsonb)::text$q$);
select pg_temp.run('n_create', 'anon', null,
  $q$select public.admin_create_promotion('{"name":"x","discount_type":"fixed","value":5}'::jsonb)::text$q$);
select pg_temp.run('c_list', 'authenticated', pg_temp.u1(), $q$select public.admin_list_promotions()::text$q$);
do $$
declare v_id uuid; v_audit_before bigint;
begin
  perform pg_temp.ok((select err is null and (res::jsonb #>> '{promotion,code}') = 'P8-ADMIN1' and (res::jsonb #>> '{promotion,is_active}') = 'true'
    from t_res where k = 'a_create'), 'admin creates a coupon (code normalised to upper case, trimmed)');
  perform pg_temp.ok((select detail = 'code_taken' from t_res where k = 'a_dup'), 'duplicate code: code_taken');
  perform pg_temp.ok((select detail = 'invalid_promotion' from t_res where k = 'a_bad1'), 'percentage above 100% refused');
  perform pg_temp.ok((select detail = 'invalid_promotion' from t_res where k = 'a_bad2'), 'cap on a fixed promotion refused');
  perform pg_temp.ok((select detail = 'invalid_promotion' from t_res where k = 'a_bad3'), 'expiry before start refused');
  perform pg_temp.ok((select detail = 'invalid_promotion' from t_res where k = 'a_bad4'), 'a malformed code refused');
  perform pg_temp.ok((select detail = 'invalid_arguments' from t_res where k = 'a_unknown'), 'an unknown field is refused (no mass assignment)');
  perform pg_temp.ok((select state = '42501' and detail = 'not_authorised' from t_res where k = 'c_create'), 'a customer cannot create a promotion (require_admin)');
  perform pg_temp.ok(pg_temp.denied('n_create'), 'anon cannot call the admin function at all');
  perform pg_temp.ok((select state = '42501' and detail = 'not_authorised' from t_res where k = 'c_list'), 'a customer cannot list promotions');

  select (res::jsonb #>> '{promotion,id}')::uuid into v_id from t_res where k = 'a_create';
  select count(*) into v_audit_before from public.admin_audit_log where target_id = v_id;
  perform pg_temp.ok(v_audit_before = 1, 'creation is audited');

  perform pg_temp.run('a_upd', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
    format($q$select public.admin_update_promotion(%L, '{"value":300,"usage_limit":null}'::jsonb)::text$q$, v_id));
  perform pg_temp.run('a_upd_same', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
    format($q$select public.admin_update_promotion(%L, '{"value":300}'::jsonb)::text$q$, v_id));
  perform pg_temp.run('a_off', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
    format($q$select public.admin_set_promotion_active(%L, false)::text$q$, v_id));
  perform pg_temp.run('a_off_same', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
    format($q$select public.admin_set_promotion_active(%L, false)::text$q$, v_id));
  perform pg_temp.run('a_missing', 'authenticated', '00000000-0000-4000-8000-0000000008ad',
    $q$select public.admin_update_promotion('00000000-0000-4000-8000-0000000008ee', '{"value":1}'::jsonb)::text$q$);
  perform pg_temp.run('a_list', 'authenticated', '00000000-0000-4000-8000-0000000008ad', $q$select public.admin_list_promotions(5, 0)::text$q$);

  perform pg_temp.ok((select (res::jsonb #>> '{promotion,value}') = '300' and (res::jsonb #> '{promotion,usage_limit}') = 'null'::jsonb
    from t_res where k = 'a_upd'), 'admin updates value and clears the usage limit');
  perform pg_temp.ok((select count(*) from public.admin_audit_log where target_id = v_id and action = 'promotion_updated') = 1
    and (select reason from public.admin_audit_log where target_id = v_id and action = 'promotion_updated') = 'changed: value, usage_limit',
    'the update is audited with the changed field names');
  perform pg_temp.ok((select err is null from t_res where k = 'a_upd_same')
    and (select count(*) from public.admin_audit_log where target_id = v_id and action = 'promotion_updated') = 1,
    'an update that changes nothing writes no audit row');
  perform pg_temp.ok((select (res::jsonb #>> '{promotion,is_active}') = 'false' from t_res where k = 'a_off')
    and (select count(*) from public.admin_audit_log where target_id = v_id and action = 'promotion_deactivated') = 1,
    'deactivation works and is audited once (repeating it is a no-op)');
  perform pg_temp.ok((select detail = 'promotion_not_found' from t_res where k = 'a_missing'), 'unknown promotion id: promotion_not_found');
  perform pg_temp.ok((select (res::jsonb ->> 'total')::int >= 12 and jsonb_array_length(res::jsonb -> 'rows') <= 5 from t_res where k = 'a_list'),
    'admin_list_promotions returns the total and honours the limit');

  perform pg_temp.run('v_deact', 'authenticated', pg_temp.u1(),
    $q$select public.validate_coupon('[{"product_id":"00000000-0000-4000-8000-0000000008b1","variant_id":null,"quantity":1}]'::jsonb, 'P8-ADMIN1')::text$q$);
  perform pg_temp.ok((select res::jsonb from t_res where k = 'v_deact') = '{"ok": false, "error": "invalid"}'::jsonb, 'a deactivated coupon validates as invalid');
end $$;

-- ---------------------------------------------------------------------------
-- 15. Constraints on the table itself
-- ---------------------------------------------------------------------------
do $$
declare v_state text;
begin
  begin insert into public.promotions (name, discount_type, value) values ('c1', 'percentage', 0); v_state := 'none';
  exception when check_violation then v_state := 'check'; end;
  perform pg_temp.ok(v_state = 'check', 'percentage value 0 is refused by the table');
  begin insert into public.promotions (code, name, discount_type, value) values ('p8-lower', 'c2', 'fixed', 1); v_state := 'none';
  exception when check_violation then v_state := 'check'; end;
  perform pg_temp.ok(v_state = 'check', 'a lower-case code cannot be stored (canonical form enforced)');
  begin insert into public.promotions (code, name, discount_type, value) values ('P8-TEN', 'c3', 'fixed', 1); v_state := 'none';
  exception when unique_violation then v_state := 'unique'; end;
  perform pg_temp.ok(v_state = 'unique', 'codes are unique');
  begin insert into public.promotion_redemptions (promotion_id, order_id, user_id, amount_cents, released_at)
        values ('00000000-0000-4000-8000-0000000008c1', pg_temp.ord_id('ten'), pg_temp.u1(), 5, now()); v_state := 'none';
  exception when check_violation or unique_violation then v_state := 'refused'; end;
  perform pg_temp.ok(v_state = 'refused', 'a release without a reason cannot be stored');
end $$;

do $$ begin raise notice 'ALL PHASE 8 TESTS PASSED'; end $$;
rollback;
