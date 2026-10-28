-- Domain separation (A6 §15): no function body names a retired identifier.
-- Extended by each rename task.
begin;
create extension if not exists pgtap with schema extensions;

select plan(25);

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

select hasnt_table('public', 'fintech_advances', 'fintech_advances is gone');
select is(pg_temp.bodies_matching('fintech_advances'), null::text[], 'no body names fintech_advances');

-- positive control: the helper really matches
select is(pg_temp.bodies_matching('POS_AGENT') @> array['issue_otp'], true, 'the guard helper finds a known body');

-- Task 3: the web domain (A6 section 15.4)
select hasnt_table('public', 'fintech_partners', 'fintech_partners is renamed');
select hasnt_table('public', 'fintech_terminals', 'fintech_terminals is renamed');
select hasnt_table('public', 'agent_codes', 'agent_codes is renamed');
select hasnt_table('public', 'commission_records', 'commission_records is renamed');
select is(pg_temp.bodies_matching('fintech_partners'), null::text[], 'no body names fintech_partners');
select is(pg_temp.bodies_matching('fintech_terminals'), null::text[], 'no body names fintech_terminals');
select is(pg_temp.bodies_matching('agent_codes'), null::text[], 'no body names agent_codes');
select is(pg_temp.bodies_matching('commission_records'), null::text[], 'no body names commission_records');
select is(pg_temp.bodies_matching('fintech_partner_id'), null::text[], 'no body names fintech_partner_id');
select is(pg_temp.bodies_matching('fintech_terminal_id'), null::text[], 'no body names fintech_terminal_id');
select is(pg_temp.bodies_matching('agent_code_id'), null::text[], 'no body names agent_code_id');
select is(pg_temp.bodies_matching('attributed_terminal_id'), null::text[], 'no body names attributed_terminal_id');
select is(pg_temp.bodies_matching('upsert_agent_code'), null::text[], 'no body names upsert_agent_code');
select is(pg_temp.bodies_matching('set_terminal_venue'), null::text[], 'no body names set_terminal_venue');
select is(pg_temp.bodies_matching('terminal_id'), null::text[], 'no body names terminal_id (network_terminal_id stripped)');

-- catalog names: constraints, indexes, policies, triggers
select is((select array_agg(conname::text order by conname) from pg_constraint
            where connamespace = 'public'::regnamespace
              and conname ~ '(^|_)fintech_(partner|terminal|advance)|agent_code|commission_records'),
          null::text[], 'no constraint keeps an old web name');
select is((select array_agg(indexname::text order by indexname) from pg_indexes
            where schemaname = 'public'
              and indexname ~ '(^|_)fintech_(partner|terminal|advance)|agent_code|commission_records'),
          null::text[], 'no index keeps an old web name');
select is((select array_agg(policyname::text order by policyname) from pg_policies
            where schemaname = 'public'
              and policyname ~ '(^|_)fintech_(partner|terminal|advance)|agent_code|commission_records'),
          null::text[], 'no policy keeps an old web name');
select is((select array_agg(tgname::text order by tgname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
              and tgname ~ '(^|_)fintech_(partner|terminal|advance)|agent_code|commission_records'),
          null::text[], 'no trigger keeps an old web name');
select is((select count(*)::int from pg_constraint
            where connamespace = 'public'::regnamespace and conname ~ '^web_(pos_partners|pos_venues|referral_codes|commissions)_'),
          (select count(*)::int from pg_constraint
            where connamespace = 'public'::regnamespace and conrelid::regclass::text in ('web_pos_partners','web_pos_venues','web_referral_codes','web_commissions')),
          'every constraint of a web table carries the new prefix');

select * from finish();
rollback;
