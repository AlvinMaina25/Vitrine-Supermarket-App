-- =============================================================================
-- PHASE 20A database test: admin_create_category() / admin_update_category().
--
-- STATUS: written for migration 20261011010000_phase20a_admin_categories.sql. NOT run against any
-- database when it was written (no PostgreSQL available in the authoring environment).
--
-- RUN (dev database with all migrations through 20261011010000 applied, owner role):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase20a_admin_categories.test.sql
-- One transaction, rolled back at the end. "FAIL: <name>" raises; "PASS: <name>" is noticed.
-- Users are simulated like the other tests: SET LOCAL ROLE + JWT settings, real require_admin().
-- =============================================================================
begin;

create or replace function pg_temp.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end; $$;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_aal text, p_sql text)
returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_detail text; v_claims jsonb;
begin
  v_claims := case when p_uid is null then null
                   else jsonb_build_object('sub', p_uid, 'role', p_role, 'aal', p_aal) end;
  perform set_config('request.jwt.claims', coalesce(v_claims::text, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_claims ->> 'sub', ''), true);
  perform set_config('request.jwt.claim.role', coalesce(v_claims ->> 'role', ''), true);
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
end; $$;

-- Must be defined BEFORE adm(): LANGUAGE sql bodies are resolved at CREATE time.
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-20a00000000' || n)::uuid $$;

-- Admin (aal2) call of any statement.
create or replace function pg_temp.adm(p_k text, p_sql text) returns void language sql as $$
  select pg_temp.run(p_k, 'authenticated', pg_temp.u(3), 'aal2', p_sql) $$;

create or replace function pg_temp.err_is(p_k text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded)', p_name; end if;
  perform pg_temp.ok(r.err is not null and r.state = p_state and r.detail is not distinct from p_detail,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ']');
end; $$;

create or replace function pg_temp.j(p_k text) returns jsonb language sql as $$
  select res::jsonb from t_res where k = p_k $$;

insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't20a-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T20A Customer"}'),
  (pg_temp.u(2), 't20a-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T20A Staff"}'),
  (pg_temp.u(3), 't20a-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T20A Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

-- ---- A. authorization -------------------------------------------------------
select pg_temp.run('cr_cust',  'authenticated', pg_temp.u(1), 'aal1', $$select public.admin_create_category('T20A One', 't20a-one')::text$$);
select pg_temp.run('cr_staff', 'authenticated', pg_temp.u(2), 'aal2', $$select public.admin_create_category('T20A One', 't20a-one')::text$$);
select pg_temp.run('cr_anon',  'anon',          null,         null,   $$select public.admin_create_category('T20A One', 't20a-one')::text$$);
select pg_temp.err_is('cr_cust',  '42501', 'not_authorised', 'A1 customer cannot create a category');
select pg_temp.err_is('cr_staff', '42501', 'not_authorised', 'A2 staff cannot create a category');
select pg_temp.ok((select err is not null and state = '42501' from t_res where k = 'cr_anon'), 'A3 anon has no EXECUTE');
select pg_temp.ok((select count(*) from public.categories where slug = 't20a-one') = 0, 'A4 refused calls wrote no category');

select pg_temp.adm('cr_ok', $$select public.admin_create_category('T20A One', 't20a-one', '  Fresh things ', null, 3, true)::text$$);
select pg_temp.ok(pg_temp.j('cr_ok') -> 'category' ->> 'slug' = 't20a-one'
  and pg_temp.j('cr_ok') -> 'category' ->> 'tagline' = 'Fresh things'
  and (pg_temp.j('cr_ok') -> 'category' ->> 'position')::int = 3
  and (pg_temp.j('cr_ok') -> 'category' ->> 'is_active')::boolean is true
  and pg_temp.j('cr_ok') -> 'category' -> 'image_url' = 'null'::jsonb,
  'A5 admin creates a category; tagline trimmed; no image');

-- Positive control for the gate: with MFA enforcement on, an aal1 admin is refused, aal2 is not.
update public.admin_security_settings set require_mfa = true;
select pg_temp.run('cr_aal1', 'authenticated', pg_temp.u(3), 'aal1', $$select public.admin_create_category('T20A Two', 't20a-two')::text$$);
select pg_temp.err_is('cr_aal1', '42501', 'mfa_required', 'A6 admin without 2FA is refused when enforcement is on');
select pg_temp.adm('cr_aal2', $$select public.admin_create_category('T20A Two', 't20a-two')::text$$);
select pg_temp.ok((select err is null from t_res where k = 'cr_aal2'), 'A7 admin with 2FA is allowed');
update public.admin_security_settings set require_mfa = false;

-- ---- B. create validation -----------------------------------------------------
select pg_temp.adm('b_name1',  $$select public.admin_create_category('A', 't20a-x')::text$$);
select pg_temp.adm('b_name81', format($$select public.admin_create_category(%L, 't20a-x')::text$$, repeat('n', 81)));
select pg_temp.adm('b_slugUp', $$select public.admin_create_category('T20A Bad', 'Bad Slug')::text$$);
select pg_temp.adm('b_slugDd', $$select public.admin_create_category('T20A Bad', 'bad--slug')::text$$);
select pg_temp.adm('b_slugLg', format($$select public.admin_create_category('T20A Bad', %L)::text$$, repeat('a', 81)));
select pg_temp.adm('b_tag121', format($$select public.admin_create_category('T20A Bad', 't20a-x', %L)::text$$, repeat('t', 121)));
select pg_temp.adm('b_desc501', format($$select public.admin_create_category('T20A Bad', 't20a-x', null, %L)::text$$, repeat('d', 501)));
select pg_temp.adm('b_pos',    $$select public.admin_create_category('T20A Bad', 't20a-x', null, null, -1)::text$$);
select pg_temp.adm('b_act',    $$select public.admin_create_category('T20A Bad', 't20a-x', null, null, 0, null)::text$$);
select pg_temp.err_is('b_name1',   'P0001', 'invalid_arguments', 'B1 name of 1 character refused');
select pg_temp.err_is('b_name81',  'P0001', 'invalid_arguments', 'B2 name of 81 characters refused');
select pg_temp.err_is('b_slugUp',  'P0001', 'invalid_arguments', 'B3 slug with capitals / spaces refused (not silently fixed)');
select pg_temp.err_is('b_slugDd',  'P0001', 'invalid_arguments', 'B4 slug with a double hyphen refused');
select pg_temp.err_is('b_slugLg',  'P0001', 'invalid_arguments', 'B5 slug over 80 characters refused');
select pg_temp.err_is('b_tag121',  'P0001', 'invalid_arguments', 'B6 tagline over 120 characters refused');
select pg_temp.err_is('b_desc501', 'P0001', 'invalid_arguments', 'B7 description over 500 characters refused');
select pg_temp.err_is('b_pos',     'P0001', 'invalid_arguments', 'B8 negative position refused');
select pg_temp.err_is('b_act',     'P0001', 'invalid_arguments', 'B9 null is_active refused');
select pg_temp.adm('b_dup', $$select public.admin_create_category('T20A Again', 't20a-one')::text$$);
select pg_temp.err_is('b_dup', '23505', 'slug_taken', 'B10 duplicate slug -> slug_taken');
select pg_temp.ok((select count(*) from public.categories where slug in ('t20a-x', 'bad-slug')) = 0, 'B11 refused creates wrote nothing');

-- ---- C. update (PATCH) ---------------------------------------------------------
create temp table t_ids as select id from public.categories where slug = 't20a-one';
select pg_temp.adm('u_ok', format($$select public.admin_update_category(%L::uuid, '{"name":"T20A Renamed","position":7,"is_active":false,"tagline":null}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.ok(pg_temp.j('u_ok') -> 'category' ->> 'name' = 'T20A Renamed'
  and (pg_temp.j('u_ok') -> 'category' ->> 'position')::int = 7
  and (pg_temp.j('u_ok') -> 'category' ->> 'is_active')::boolean is false
  and pg_temp.j('u_ok') -> 'category' -> 'tagline' = 'null'::jsonb
  and pg_temp.j('u_ok') -> 'category' ->> 'slug' = 't20a-one',
  'C1 patch changes only the keys sent (slug untouched); null clears the tagline');
select pg_temp.ok((select count(*) from public.categories where slug = 't20a-one' and is_active) = 0,
  'C2 deactivated, not deleted: the row still exists');

select pg_temp.adm('u_img',   format($$select public.admin_update_category(%L::uuid, '{"image_url":"https://x.test/a.jpg"}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_par',   format($$select public.admin_update_category(%L::uuid, '{"parent_id":null}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_empty', format($$select public.admin_update_category(%L::uuid, '{}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_null',  format($$select public.admin_update_category(%L::uuid, '{"name":null}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_frac',  format($$select public.admin_update_category(%L::uuid, '{"position":1.5}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_actstr', format($$select public.admin_update_category(%L::uuid, '{"is_active":"yes"}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_slug',  format($$select public.admin_update_category(%L::uuid, '{"slug":"T 20"}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_dup',   format($$select public.admin_update_category(%L::uuid, '{"slug":"t20a-two"}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.adm('u_none',  $$select public.admin_update_category('00000000-0000-4000-8000-20affffffff0'::uuid, '{"name":"Nope"}'::jsonb)::text$$);
select pg_temp.err_is('u_img',    'P0001', 'unsupported_field', 'C3 image_url cannot be set here (Phase 20B function does that)');
select pg_temp.err_is('u_par',    'P0001', 'unsupported_field', 'C4 parent_id cannot be set here');
select pg_temp.err_is('u_empty',  'P0001', 'invalid_arguments', 'C5 empty patch refused');
select pg_temp.err_is('u_null',   'P0001', 'invalid_arguments', 'C6 name cannot be null');
select pg_temp.err_is('u_frac',   'P0001', 'invalid_arguments', 'C7 fractional position refused');
select pg_temp.err_is('u_actstr', 'P0001', 'invalid_arguments', 'C8 is_active must be a boolean');
select pg_temp.err_is('u_slug',   'P0001', 'invalid_arguments', 'C9 invalid slug refused');
select pg_temp.err_is('u_dup',    '23505', 'slug_taken',        'C10 duplicate slug refused');
select pg_temp.err_is('u_none',   'P0001', 'category_not_found', 'C11 unknown category');

-- ---- D. audit -------------------------------------------------------------------
select pg_temp.ok((select count(*) from public.admin_audit_log where action = 'category_created' and actor_id = pg_temp.u(3)) = 2,
  'D1 two creates (T20A One, T20A Two) were audited');
select pg_temp.ok((select count(*) from public.admin_audit_log where action = 'category_updated' and target_id = (select id from t_ids)
                   and reason like 'fields: name, tagline, position, is_active%is_active t -> f') = 1,
  'D2 the update was audited once, with field names and the is_active change only');
create temp table t_cnt as select count(*) n from public.admin_audit_log;
select pg_temp.adm('u_noop', format($$select public.admin_update_category(%L::uuid, '{"name":"T20A Renamed"}'::jsonb)::text$$, (select id from t_ids)));
select pg_temp.ok((select err is null from t_res where k = 'u_noop') and (select count(*) from public.admin_audit_log) = (select n from t_cnt),
  'D3 a patch that changes nothing succeeds and writes no audit row');
select pg_temp.ok(not exists (select 1 from public.admin_audit_log where reason like '%T20A Renamed%'),
  'D4 audit rows do not copy names or descriptions');

-- ---- E. function security / privileges -------------------------------------------
select pg_temp.ok(not has_table_privilege('authenticated', 'public.categories', 'INSERT')
  and not has_table_privilege('authenticated', 'public.categories', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.categories', 'DELETE')
  and not has_table_privilege('anon', 'public.categories', 'INSERT'),
  'E1 browser roles still cannot write public.categories directly');
select pg_temp.ok((select bool_and(p.prosecdef and not has_function_privilege('anon', p.oid, 'EXECUTE')
                                   and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                                   and position('public.require_admin()' in p.prosrc) > 0
                                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%')
                   from pg_proc p where p.pronamespace = 'public'::regnamespace
                    and p.proname in ('admin_create_category', 'admin_update_category')),
  'E2 both functions: SECURITY DEFINER, pinned search_path, gated, anon cannot execute, authenticated can');

-- ---- F. storefront visibility -------------------------------------------------------
select pg_temp.run('anon_cats', 'anon', null, null, $$select count(*)::text from public.categories where slug = 't20a-one'$$);
select pg_temp.ok((select res from t_res where k = 'anon_cats') = '0', 'F1 the deactivated category is invisible to anon (RLS: public read active)');
select pg_temp.run('adm_cats', 'authenticated', pg_temp.u(3), 'aal2', $$select count(*)::text from public.categories where slug = 't20a-one'$$);
select pg_temp.ok((select res from t_res where k = 'adm_cats') = '1', 'F2 the admin read-all policy still shows it to an admin (admin edit screen)');

do $$ begin raise notice 'ALL PHASE 20A TESTS PASSED'; end $$;
rollback;
