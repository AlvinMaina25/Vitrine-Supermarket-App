-- =============================================================================
-- PHASE 6I.2 CLEANUP - drop the stale admin_list_products(integer) overload. NOT APPLIED / NOT RUN.
-- Apply once, after 20261005110000. One transaction.
--
-- WHY: Phase 6C.1A.2 replaced admin_list_products(integer) with
--   admin_list_products(integer, integer, text, boolean, uuid) and dropped the old one, because two
--   overloads whose arguments all have defaults make admin_list_products() / (p_limit => n) ambiguous.
--   A live database was found still holding BOTH (found by the Phase 6B.2 test, check F9).
--   The leftover is gated (require_admin), SECURITY DEFINER, and not executable by anon or PUBLIC:
--   it is drift and an ambiguity risk, not a privilege hole.
-- DOES: drops exactly public.admin_list_products(integer). No CASCADE: if anything depends on it,
--   the drop fails and nothing changes.
-- DOES NOT: touch the current 5-argument function, any other function, table, grant, policy or trigger.
--   On a database that already has only the 5-argument version it refuses to run
--   (nothing to drop), which is the correct state.
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is null then
    raise exception 'Cleanup precondition failed: the current admin_list_products(integer,integer,text,boolean,uuid) is missing. Apply 6C.1A.2 first.';
  end if;
  if to_regprocedure('public.admin_list_products(integer)') is null then
    raise exception 'Nothing to do: admin_list_products(integer) does not exist (already clean). Not running.';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') <> 2 then
    raise exception 'Cleanup precondition failed: expected exactly two admin_list_products overloads. Inspect before continuing.';
  end if;

  perform set_config('p6i2c.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p6i2c.other_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc) || '/' || coalesce(p.proacl::text, ''), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.oid <> 'public.admin_list_products(integer)'::regprocedure), true);
end
$pre$;

drop function public.admin_list_products(integer);

do $chk$
begin
  if to_regprocedure('public.admin_list_products(integer)') is not null then
    raise exception 'Cleanup self-check failed: the stale overload still exists.';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') <> 1 then
    raise exception 'Cleanup self-check failed: expected exactly one admin_list_products().';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::bigint + 1
       is distinct from current_setting('p6i2c.fn_count', true)::bigint then
    raise exception 'Cleanup self-check failed: more or fewer than one function was removed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc) || '/' || coalesce(p.proacl::text, ''), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p where p.pronamespace = 'public'::regnamespace)
     is distinct from current_setting('p6i2c.other_hash', true) then
    raise exception 'Cleanup self-check failed: another function or its grants changed.';
  end if;
  if not has_function_privilege('authenticated', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE') then
    raise exception 'Cleanup self-check failed: the current admin_list_products() grants are wrong.';
  end if;
end
$chk$;

commit;
