-- =============================================================================
-- PHASE 6F.4 - delivery configuration LOCKDOWN. Apply ONCE, after 20261005020000 (6F.1B).
-- One transaction. Not applied anywhere yet.
--
-- WHY: since 6F.1A/6F.1B every delivery change goes through admin-only SECURITY DEFINER
--   functions (gate, validation, audit row). The direct table write paths that predate them
--   (column grants from 20260930030000 plus the admin INSERT/UPDATE policies from 5B.2) bypass
--   the audit log and the capacity / immutability rules, and the UI no longer uses them.
--   Supabase default privileges may also have handed DELETE and TRUNCATE (which RLS does not
--   restrict) on these tables to anon and authenticated. This migration closes all of that.
--
-- DOES:  on delivery_methods, delivery_zones, delivery_zone_fees, delivery_slot_templates and
--   delivery_slot_overrides:
--     1. drops every INSERT / UPDATE / DELETE write policy (refuses to run if an ALL policy exists,
--        because dropping that would also change reads);
--     2. revokes INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER (table and column
--        level) from PUBLIC, anon and authenticated.
-- DOES NOT: touch any SELECT grant or SELECT policy, any function, create_order(),
--   validate_delivery_selection(), resolve_delivery_fee(), get_delivery_slot_availability(),
--   service_role, or any earlier migration. The admin functions are SECURITY DEFINER and keep
--   working: they run as the table owner, not as authenticated.
--
-- GUARDS: refuses to run if the 6F.1A/6F.1B functions are missing, if RLS is off on any of the
--   five tables, if an ALL policy exists, or if the lockdown is already complete. The final
--   self-check aborts the whole transaction if any write privilege or write policy remains, or
--   if any SELECT privilege / SELECT policy / function EXECUTE privilege differs from before.
-- =============================================================================
begin;

-- ---- snapshot helper (temp; dropped at the end) -----------------------------------------
create function pg_temp.lockdown_snapshot()
returns table (kind text, key text, val text)
language sql
as $$
  select 'select_priv', r.role || ' ' || t.name,
         has_table_privilege(r.role, ('public.' || t.name)::regclass, 'SELECT')::text
  from unnest(array['anon', 'authenticated']) as r(role)
  cross join unnest(array['delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                          'delivery_slot_templates', 'delivery_slot_overrides']) as t(name)
  union all
  select 'select_policy', p.tablename || ' ' || p.policyname,
         p.roles::text || ' | ' || coalesce(p.qual, '') || ' | ' || coalesce(p.with_check, '')
  from pg_policies p
  where p.schemaname = 'public' and p.cmd = 'SELECT'
    and p.tablename in ('delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                        'delivery_slot_templates', 'delivery_slot_overrides')
  union all
  select 'exec', r.role || ' ' || p.oid::regprocedure::text,
         has_function_privilege(r.role, p.oid, 'EXECUTE')::text
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join unnest(array['anon', 'authenticated']) as r(role)
  where n.nspname = 'public'
    and (p.proname in ('create_order', 'validate_delivery_selection', 'resolve_delivery_fee',
                       'get_delivery_slot_availability', 'validate_delivery_slot',
                       'lock_delivery_slot', 'delivery_zone_covers_address')
         or p.proname in ('admin_list_delivery_config', 'admin_save_delivery_zone',
                          'admin_set_delivery_zone_active', 'admin_save_delivery_zone_fee',
                          'admin_set_delivery_zone_fee_active', 'admin_update_delivery_method',
                          'admin_list_delivery_slots', 'admin_save_delivery_slot_template',
                          'admin_set_delivery_slot_template_active',
                          'admin_save_delivery_slot_override', 'admin_clear_delivery_slot_override'))
$$;

-- ---- preconditions + refuse-to-run-twice ------------------------------------------------
do $pre$
declare
  v_tables text[] := array['delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                           'delivery_slot_templates', 'delivery_slot_overrides'];
  v_t text;
  v_sig text;
  v_any_write boolean := false;
begin
  foreach v_sig in array array[
    'public.require_admin()',
    'public.admin_list_delivery_config()',
    'public.admin_save_delivery_zone(uuid,text,text,text,text[],text,integer)',
    'public.admin_set_delivery_zone_active(uuid,boolean,text)',
    'public.admin_save_delivery_zone_fee(uuid,uuid,text,numeric,numeric,numeric)',
    'public.admin_set_delivery_zone_fee_active(uuid,boolean,text)',
    'public.admin_update_delivery_method(text,numeric,numeric,numeric,boolean,text)',
    'public.admin_list_delivery_slots(date,date)',
    'public.admin_save_delivery_slot_template(uuid,text,time without time zone,time without time zone,integer,numeric,integer)',
    'public.admin_set_delivery_slot_template_active(uuid,boolean,text)',
    'public.admin_save_delivery_slot_override(uuid,date,numeric,boolean,text)',
    'public.admin_clear_delivery_slot_override(uuid,date,text)',
    'public.validate_delivery_selection(text,uuid,integer)',
    'public.get_delivery_slot_availability(date,date)'
  ] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6F.4 precondition failed: % does not exist. Apply 6F.1A and 6F.1B first.', v_sig;
    end if;
  end loop;

  foreach v_t in array v_tables loop
    if to_regclass('public.' || v_t) is null then
      raise exception 'Phase 6F.4 precondition failed: table public.% does not exist.', v_t;
    end if;
    if not (select c.relrowsecurity from pg_class c where c.oid = ('public.' || v_t)::regclass) then
      raise exception 'Phase 6F.4 precondition failed: row level security is off on public.%.', v_t;
    end if;
    if exists (select 1 from pg_policies where schemaname = 'public' and tablename = v_t and cmd = 'ALL') then
      raise exception 'Phase 6F.4 precondition failed: public.% has an ALL policy; dropping it would also change reads. Review it by hand first.', v_t;
    end if;
    if has_table_privilege('authenticated', ('public.' || v_t)::regclass, 'INSERT, UPDATE, DELETE, TRUNCATE')
       or has_any_column_privilege('authenticated', ('public.' || v_t)::regclass, 'INSERT, UPDATE')
       or has_table_privilege('anon', ('public.' || v_t)::regclass, 'INSERT, UPDATE, DELETE, TRUNCATE')
       or has_any_column_privilege('anon', ('public.' || v_t)::regclass, 'INSERT, UPDATE')
       or exists (select 1 from pg_policies where schemaname = 'public' and tablename = v_t
                  and cmd in ('INSERT', 'UPDATE', 'DELETE')) then
      v_any_write := true;
    end if;
  end loop;

  if not v_any_write then
    raise exception 'Phase 6F.4 appears to be applied already (no write privilege or write policy is left on the delivery tables). Not running it twice.';
  end if;
end
$pre$;

create temp table lockdown_before on commit drop as
  select * from pg_temp.lockdown_snapshot();

-- ---- 1. drop write policies (INSERT / UPDATE / DELETE only) -----------------------------
do $pol$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                        'delivery_slot_templates', 'delivery_slot_overrides')
      and cmd in ('INSERT', 'UPDATE', 'DELETE')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end
$pol$;

-- ---- 2. revoke direct writes (table level also removes column-level grants) -------------
revoke insert, update, delete, truncate, references, trigger
  on public.delivery_methods from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.delivery_zones from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.delivery_zone_fees from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.delivery_slot_templates from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.delivery_slot_overrides from public, anon, authenticated;

-- ---- 3. self-check (aborts the whole transaction if anything is off) --------------------
do $check$
declare
  v_t text;
  v_role text;
  v_diff integer;
  v_sig text;
begin
  foreach v_t in array array['delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                             'delivery_slot_templates', 'delivery_slot_overrides'] loop
    foreach v_role in array array['anon', 'authenticated'] loop
      if has_table_privilege(v_role, ('public.' || v_t)::regclass,
                             'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         or has_any_column_privilege(v_role, ('public.' || v_t)::regclass, 'INSERT, UPDATE, REFERENCES') then
        raise exception 'Phase 6F.4 self-check failed: % still holds a write privilege on public.%.', v_role, v_t;
      end if;
    end loop;
    if exists (select 1 from pg_policies where schemaname = 'public' and tablename = v_t
               and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')) then
      raise exception 'Phase 6F.4 self-check failed: a write policy remains on public.%.', v_t;
    end if;
    if not (select c.relrowsecurity from pg_class c where c.oid = ('public.' || v_t)::regclass) then
      raise exception 'Phase 6F.4 self-check failed: row level security is off on public.%.', v_t;
    end if;
  end loop;

  -- Reads and function privileges must be exactly as before.
  select count(*) into v_diff
  from (select kind, key, val from lockdown_before
        except select kind, key, val from pg_temp.lockdown_snapshot()) a;
  if v_diff <> 0 or exists (select kind, key, val from pg_temp.lockdown_snapshot()
                            except select kind, key, val from lockdown_before) then
    raise exception 'Phase 6F.4 self-check failed: a SELECT privilege, SELECT policy or function privilege changed.';
  end if;

  -- The admin functions still work because they run as their owner, never as a browser role.
  foreach v_sig in array array[
    'public.admin_save_delivery_zone(uuid,text,text,text,text[],text,integer)',
    'public.admin_save_delivery_zone_fee(uuid,uuid,text,numeric,numeric,numeric)',
    'public.admin_update_delivery_method(text,numeric,numeric,numeric,boolean,text)',
    'public.admin_save_delivery_slot_template(uuid,text,time without time zone,time without time zone,integer,numeric,integer)',
    'public.admin_save_delivery_slot_override(uuid,date,numeric,boolean,text)'
  ] loop
    if not exists (
      select 1 from pg_proc p
      where p.oid = v_sig::regprocedure and p.prosecdef
        and pg_get_userbyid(p.proowner) not in ('anon', 'authenticated', 'public')
        and has_table_privilege(p.proowner, 'public.delivery_zones', 'INSERT, UPDATE')
        and has_table_privilege(p.proowner, 'public.delivery_slot_overrides', 'INSERT, UPDATE')
    ) then
      raise exception 'Phase 6F.4 self-check failed: % would not be able to write as its owner.', v_sig;
    end if;
  end loop;
end
$check$;

drop function pg_temp.lockdown_snapshot();

commit;
