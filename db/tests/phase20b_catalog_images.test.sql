-- =============================================================================
-- PHASE 20B database test: catalog-images bucket, storage policies, admin_set_product_image() / admin_set_category_image().
--
-- STATUS: written for migration 20261011020000_phase20b_catalog_images.sql. NOT run against any
-- database when it was written (no PostgreSQL available in the authoring environment).
--
-- RUN (dev database with all migrations through 20261011020000 applied, owner role):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase20b_catalog_images.test.sql
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
  select ('00000000-0000-4000-8000-20b00000000' || n)::uuid $$;

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

create or replace function pg_temp.j(p_k text) returns jsonb language sql as $$
  select res::jsonb from t_res where k = p_k $$;

insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't20b-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T20B Customer"}'),
  (pg_temp.u(2), 't20b-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T20B Staff"}'),
  (pg_temp.u(3), 't20b-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T20B Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

-- Fixtures (inserted as the owner): one product, one category, and uploaded files.
insert into public.products (slug, name, price_cents) values ('t20b-product', 'T20B Product', 1000);
insert into public.categories (slug, name) values ('t20b-category', 'T20B Category');
create temp table t_ids as
  select (select id from public.products where slug = 't20b-product') as pid,
         (select id from public.categories where slug = 't20b-category') as cid;

-- Files that "were uploaded" (owner insert; the policy tests below use real roles).
insert into storage.objects (bucket_id, name) values
  ('catalog-images', 'products/11111111-1111-4111-8111-111111111111.jpg'),
  ('catalog-images', 'products/22222222-2222-4222-8222-222222222222.png'),
  ('catalog-images', 'categories/33333333-3333-4333-8333-333333333333.webp');

-- ---- A. bucket + policies (catalog) -------------------------------------------------
select pg_temp.ok((select public is true and file_size_limit = 2097152
                          and allowed_mime_types @> array['image/jpeg','image/png','image/webp']
                          and allowed_mime_types <@ array['image/jpeg','image/png','image/webp']
                   from storage.buckets where id = 'catalog-images'),
  'A1 bucket catalog-images is public, 2 MB, jpeg / png / webp only');
select pg_temp.ok((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                   and policyname like 'Catalog images:%' and roles = '{authenticated}') = 4,
  'A2 four catalog-images storage policies, all for authenticated only (none for anon / public)');

-- ---- B. storage write policies (behaviour) ------------------------------------------
select pg_temp.run('s_cust',  'authenticated', pg_temp.u(1), 'aal2', $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg')$$);
select pg_temp.run('s_staff', 'authenticated', pg_temp.u(2), 'aal2', $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg')$$);
select pg_temp.run('s_anon',  'anon',          null,         null,   $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg')$$);
select pg_temp.ok((select err is not null from t_res where k = 's_cust'),  'B1 a customer cannot upload to catalog-images');
select pg_temp.ok((select err is not null from t_res where k = 's_staff'), 'B2 staff cannot upload to catalog-images');
select pg_temp.ok((select err is not null from t_res where k = 's_anon'),  'B3 anon cannot upload to catalog-images');

select pg_temp.adm('s_adm', $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg')$$);
select pg_temp.ok((select err is null from t_res where k = 's_adm'), 'B4 an admin with 2FA can upload a well-named file');
select pg_temp.adm('s_badname', $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/holiday photo.jpg')$$);
select pg_temp.ok((select err is not null from t_res where k = 's_badname'), 'B5 an admin cannot upload an original / non-uuid file name');
select pg_temp.adm('s_otherbucket', $$insert into storage.objects (bucket_id, name) values ('some-other-bucket', 'products/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg')$$);
select pg_temp.ok((select err is not null from t_res where k = 's_otherbucket'), 'B6 the catalog policy does not open other buckets');

update public.admin_security_settings set require_mfa = true;
select pg_temp.run('s_aal1', 'authenticated', pg_temp.u(3), 'aal1', $$insert into storage.objects (bucket_id, name) values ('catalog-images', 'products/dddddddd-dddd-4ddd-8ddd-dddddddddddd.jpg')$$);
select pg_temp.ok((select err is not null from t_res where k = 's_aal1'), 'B7 an admin without 2FA cannot upload when enforcement is on');
update public.admin_security_settings set require_mfa = false;

-- ---- C. admin_set_product_image -----------------------------------------------------
select pg_temp.run('p_cust',  'authenticated', pg_temp.u(1), 'aal2', format($$select public.admin_set_product_image(%L::uuid, null)::text$$, (select pid from t_ids)));
select pg_temp.run('p_staff', 'authenticated', pg_temp.u(2), 'aal2', format($$select public.admin_set_product_image(%L::uuid, null)::text$$, (select pid from t_ids)));
select pg_temp.run('p_anon',  'anon',          null,         null,   format($$select public.admin_set_product_image(%L::uuid, null)::text$$, (select pid from t_ids)));
select pg_temp.err_is('p_cust',  '42501', 'not_authorised', 'C1 customer cannot set a product picture');
select pg_temp.err_is('p_staff', '42501', 'not_authorised', 'C2 staff cannot set a product picture');
select pg_temp.ok((select err is not null and state = '42501' from t_res where k = 'p_anon'), 'C3 anon has no EXECUTE');

select pg_temp.adm('p_ok', format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/11111111-1111-4111-8111-111111111111.jpg')::text$$, (select pid from t_ids)));
select pg_temp.ok(pg_temp.j('p_ok') -> 'product' ->> 'image_url' = 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/11111111-1111-4111-8111-111111111111.jpg'
  and (select image_url from public.products where slug = 't20b-product') like '%/catalog-images/products/11111111-%',
  'C4 admin sets a product picture; the row is returned and stored');
select pg_temp.ok((select count(*) from public.admin_audit_log where action = 'product_image_set' and target_id = (select pid from t_ids)
                   and reason = 'image products/11111111-1111-4111-8111-111111111111.jpg') = 1,
  'C5 the change was audited once, with the object name only');

create temp table t_cnt as select count(*) n from public.admin_audit_log;
select pg_temp.adm('p_same', format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/11111111-1111-4111-8111-111111111111.jpg')::text$$, (select pid from t_ids)));
select pg_temp.ok((select err is null from t_res where k = 'p_same') and (select count(*) from public.admin_audit_log) = (select n from t_cnt),
  'C6 setting the same picture again writes no audit row');

select pg_temp.adm('p_http',   format($$select public.admin_set_product_image(%L::uuid, 'http://example.supabase.co/storage/v1/object/public/catalog-images/products/22222222-2222-4222-8222-222222222222.png')::text$$, (select pid from t_ids)));
select pg_temp.adm('p_query',  format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/22222222-2222-4222-8222-222222222222.png?x=1')::text$$, (select pid from t_ids)));
select pg_temp.adm('p_bucket', format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/other-bucket/products/22222222-2222-4222-8222-222222222222.png')::text$$, (select pid from t_ids)));
select pg_temp.adm('p_folder', format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/categories/33333333-3333-4333-8333-333333333333.webp')::text$$, (select pid from t_ids)));
select pg_temp.adm('p_local',  format($$select public.admin_set_product_image(%L::uuid, '/products/milk.jpg')::text$$, (select pid from t_ids)));
select pg_temp.adm('p_ext',    format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/22222222-2222-4222-8222-222222222222.svg')::text$$, (select pid from t_ids)));
select pg_temp.err_is('p_http',   'P0001', 'invalid_image_url', 'C7 http (not https) refused');
select pg_temp.err_is('p_query',  'P0001', 'invalid_image_url', 'C8 a query string is refused');
select pg_temp.err_is('p_bucket', 'P0001', 'invalid_image_url', 'C9 another bucket is refused');
select pg_temp.err_is('p_folder', 'P0001', 'invalid_image_url', 'C10 a category picture cannot be linked to a product');
select pg_temp.err_is('p_local',  'P0001', 'invalid_image_url', 'C11 a /path is refused (existing paths stay as they are; this function does not write them)');
select pg_temp.err_is('p_ext',    'P0001', 'invalid_image_url', 'C12 a file type outside jpg / png / webp is refused');

select pg_temp.adm('p_ghost', format($$select public.admin_set_product_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/99999999-9999-4999-8999-999999999999.jpg')::text$$, (select pid from t_ids)));
select pg_temp.err_is('p_ghost', 'P0001', 'image_not_found', 'C13 a file that was never uploaded cannot be linked');
select pg_temp.adm('p_noid', $$select public.admin_set_product_image(null, null)::text$$);
select pg_temp.err_is('p_noid', 'P0001', 'invalid_arguments', 'C14 a missing product id is refused');
select pg_temp.adm('p_unknown', $$select public.admin_set_product_image('00000000-0000-4000-8000-0000000000ff'::uuid, null)::text$$);
select pg_temp.err_is('p_unknown', 'P0001', 'product_not_found', 'C15 an unknown product is refused');
select pg_temp.ok((select image_url from public.products where slug = 't20b-product') like '%/products/11111111-%',
  'C16 every refused call left the picture untouched');

select pg_temp.adm('p_rm', format($$select public.admin_set_product_image(%L::uuid, null)::text$$, (select pid from t_ids)));
select pg_temp.ok(pg_temp.j('p_rm') -> 'product' -> 'image_url' = 'null'::jsonb
  and (select image_url from public.products where slug = 't20b-product') is null
  and (select count(*) from public.admin_audit_log where action = 'product_image_removed' and target_id = (select pid from t_ids)) = 1,
  'C17 null removes the picture and is audited');
select pg_temp.ok((select count(*) from storage.objects where bucket_id = 'catalog-images' and name like 'products/11111111-%') = 1,
  'C18 removing the link did not delete the file (past orders may still show it)');

-- ---- D. admin_set_category_image ----------------------------------------------------
select pg_temp.run('c_cust', 'authenticated', pg_temp.u(1), 'aal2', format($$select public.admin_set_category_image(%L::uuid, null)::text$$, (select cid from t_ids)));
select pg_temp.err_is('c_cust', '42501', 'not_authorised', 'D1 customer cannot set a category picture');
select pg_temp.adm('c_ok', format($$select public.admin_set_category_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/categories/33333333-3333-4333-8333-333333333333.webp')::text$$, (select cid from t_ids)));
select pg_temp.ok(pg_temp.j('c_ok') -> 'category' ->> 'image_url' like '%/categories/33333333-%'
  and (select count(*) from public.admin_audit_log where action = 'category_image_set' and target_id = (select cid from t_ids)) = 1,
  'D2 admin sets a category picture, audited');
select pg_temp.adm('c_wrong', format($$select public.admin_set_category_image(%L::uuid, 'https://example.supabase.co/storage/v1/object/public/catalog-images/products/11111111-1111-4111-8111-111111111111.jpg')::text$$, (select cid from t_ids)));
select pg_temp.err_is('c_wrong', 'P0001', 'invalid_image_url', 'D3 a product picture cannot be linked to a category');
select pg_temp.adm('c_unknown', $$select public.admin_set_category_image('00000000-0000-4000-8000-0000000000ff'::uuid, null)::text$$);
select pg_temp.err_is('c_unknown', 'P0001', 'category_not_found', 'D4 an unknown category is refused');
select pg_temp.adm('c_rm', format($$select public.admin_set_category_image(%L::uuid, null)::text$$, (select cid from t_ids)));
select pg_temp.ok((select image_url from public.categories where slug = 't20b-category') is null
  and (select count(*) from public.admin_audit_log where action = 'category_image_removed' and target_id = (select cid from t_ids)) = 1,
  'D5 null removes the category picture, audited');

-- ---- E. shape of the two functions -------------------------------------------------
select pg_temp.ok((select count(*) = 2 and bool_and(p.prosecdef)
                          and bool_and(coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%')
                          and bool_and(p.prosrc like '%public.require_admin()%')
                          and bool_and(p.prosrc like '%insert into public.admin_audit_log%')
                          and bool_and(not has_function_privilege('anon', p.oid, 'EXECUTE'))
                          and bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                   from pg_proc p where p.pronamespace = 'public'::regnamespace
                    and p.proname in ('admin_set_product_image', 'admin_set_category_image')),
  'E1 both functions: SECURITY DEFINER, pinned search_path, gated, audited, anon cannot execute, authenticated can');

do $$ begin raise notice 'ALL PHASE 20B TESTS PASSED'; end $$;
rollback;
