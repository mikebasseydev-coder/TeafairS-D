-- Spec D1 — locations and routing. Task 1: Nigerian states and LGAs (§3.1).
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

-- ── Task 1: ng_states / ng_lgas (§3.1) ──────────────────────────────────
select is((select count(*)::int from public.ng_states), 37, 'exactly 37 states (FCT included)');
select is((select count(*)::int from public.ng_lgas), 774, 'exactly 774 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'LA'), 20, 'Lagos has 20 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'FC'), 6, 'FCT has 6 area councils');
select is((select id from public.ng_lgas where state_code = 'LA' and name = 'Ikeja'),
          md5('ng_lga:LA:Ikeja')::uuid, 'LGA ids are deterministic');
select ok(has_table_privilege('authenticated', 'public.ng_lgas', 'select'), 'authenticated reads LGAs');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'insert'), 'no write grant on LGAs');
select throws_ok($$insert into public.ng_states values ('lagos', 'X')$$, '23514', null, 'state code is two capitals');

select ok(not has_table_privilege('authenticated', 'public.ng_states', 'insert')
       and not has_table_privilege('authenticated', 'public.ng_states', 'update')
       and not has_table_privilege('authenticated', 'public.ng_states', 'delete'), 'no write grant on states');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'update')
       and not has_table_privilege('authenticated', 'public.ng_lgas', 'delete'), 'no update/delete grant on LGAs');
select is((select count(*)::int from public.ng_lgas where (state_code, name) in (
  ('LA','Ikeja'), ('LA','Eti-Osa'), ('OY','Oyo West'), ('NI','Munya'),
  ('NA','Nasarawa Eggon'), ('FC','Abuja Municipal'), ('AD','Girei'))), 7,
  'spot-checked LGA names exist under their state');
select * from finish();
rollback;
