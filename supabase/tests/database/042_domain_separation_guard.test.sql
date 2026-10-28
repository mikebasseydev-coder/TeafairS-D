-- Domain separation (A6 §15): no function body names a retired identifier.
-- Extended by each rename task.
begin;
create extension if not exists pgtap with schema extensions;

select plan(2);

create function pg_temp.bodies_matching(p_pattern text) returns text[]
language sql stable as $$
  select array_agg(proname::text order by proname)
    from pg_proc
   where pronamespace = 'public'::regnamespace
     and regexp_replace(prosrc, 'network_terminal_id', '', 'g') ~ p_pattern
$$;

select enum_has_labels('public', 'tenant_role_enum',
  array['ZSM','TM','ASM','DSM','DSA','POS_AGENT','RETAIL_SHOP_OWNER','ZSA','ASA']);
select is(pg_temp.bodies_matching('FINTECH_AGENT'), null::text[], 'no body names FINTECH_AGENT');

select * from finish();
rollback;
