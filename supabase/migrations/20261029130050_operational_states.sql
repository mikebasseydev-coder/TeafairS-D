-- Addendum A6 §18.4 (Task 1f; user, 2026-10-30) — operational states.
-- A platform administrator switches each Nigerian state on, separately for the
-- Teafair app and for Teafairweb, as Teafair becomes fully operational there.
-- Both switches are off by default. Off stops NEW work only: new web orders,
-- storefront locations and web routing, and new app work (Monvelo enrolment,
-- supply days, pledges; later trade orders and financing requests). Orders
-- already placed, dispatch, delivery, refunds, repayments and payouts are
-- never blocked.

-- ── operational_states ──────────────────────────────────────────────────
create table public.operational_states (
  state_code   text primary key references public.ng_states (code) on delete restrict,
  app_enabled  boolean not null default false,
  web_enabled  boolean not null default false,
  updated_by   uuid references public.profiles (id) on delete restrict,
  updated_at   timestamptz not null default now()
);
alter table public.operational_states enable row level security;
create index idx_operational_states_updated_by on public.operational_states (updated_by);
insert into public.operational_states (state_code) select code from public.ng_states;

-- anon holds nothing (003): the public storefront reads through the
-- SECURITY DEFINER storefront_locations, so it needs no grant here.
revoke all on public.operational_states from anon, authenticated, service_role;
grant select on public.operational_states to authenticated;
create policy operational_states_select on public.operational_states
  for select to authenticated using (true);

-- ── operational_state_events: insert-only history ───────────────────────
create table public.operational_state_events (
  id           uuid primary key default gen_random_uuid(),
  state_code   text not null references public.ng_states (code) on delete restrict,
  app_enabled  boolean not null,
  web_enabled  boolean not null,
  changed_by   uuid not null references public.profiles (id) on delete restrict,
  changed_at   timestamptz not null default now(),
  reason       text not null check (btrim(reason) <> '')
);
alter table public.operational_state_events enable row level security;
create index idx_operational_state_events_state on public.operational_state_events (state_code, changed_at);
create index idx_operational_state_events_changed_by on public.operational_state_events (changed_by);

create function public.operational_state_events_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'operational state history is insert-only' using errcode = 'P0001';
end;
$$;
revoke all on function public.operational_state_events_insert_only() from public, anon, authenticated, service_role;
create trigger operational_state_events_no_change before update or delete on public.operational_state_events
  for each row execute function public.operational_state_events_insert_only();
create trigger operational_state_events_no_truncate before truncate on public.operational_state_events
  for each statement execute function public.operational_state_events_insert_only();

revoke all on public.operational_state_events from anon, authenticated, service_role;
grant select on public.operational_state_events to authenticated;
create policy operational_state_events_select on public.operational_state_events
  for select to authenticated using (true);

-- ── helpers ─────────────────────────────────────────────────────────────
create function public.state_app_operational(p_state_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select o.app_enabled from public.operational_states o where o.state_code = p_state_code), false);
$$;
revoke all on function public.state_app_operational(text) from public, anon;
grant execute on function public.state_app_operational(text) to authenticated, service_role;

create function public.state_web_operational(p_state_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select o.web_enabled from public.operational_states o where o.state_code = p_state_code), false);
$$;
revoke all on function public.state_web_operational(text) from public, anon;
grant execute on function public.state_web_operational(text) to authenticated, service_role;

-- the state of a territory, through its zone
create function public.territory_state_code(p_tenant_id uuid, p_territory_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select z.state_code
    from public.territories t
    join public.zones z on z.tenant_id = t.tenant_id and z.id = t.zone_id
   where t.tenant_id = p_tenant_id and t.id = p_territory_id;
$$;
revoke all on function public.territory_state_code(uuid, uuid) from public, anon, authenticated, service_role;

-- ── brand opt-in (user, 2026-10-30): platform master + tenant choice ────
alter table public.contact_report_decisions drop constraint contact_report_decisions_subject_check;
alter table public.contact_report_decisions add constraint contact_report_decisions_subject_check
  check (subject in ('BRAND_TERMS', 'MONVELO_SETTINGS', 'FEES', 'CATALOGUE', 'STOCK', 'DISTRIBUTION', 'OTHER'));

create table public.tenant_operational_states (
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  state_code   text not null references public.ng_states (code) on delete restrict,
  app_enabled  boolean not null default false,
  web_enabled  boolean not null default false,
  decision_id  uuid not null,
  updated_by   uuid references public.profiles (id) on delete restrict,
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, state_code),
  foreign key (tenant_id, decision_id) references public.contact_report_decisions (tenant_id, id) on delete restrict
);
alter table public.tenant_operational_states enable row level security;
create index idx_tenant_operational_states_decision on public.tenant_operational_states (tenant_id, decision_id);
create index idx_tenant_operational_states_state on public.tenant_operational_states (state_code);
create index idx_tenant_operational_states_updated_by on public.tenant_operational_states (updated_by);
revoke all on public.tenant_operational_states from anon, authenticated, service_role;
grant select on public.tenant_operational_states to authenticated;
create policy tenant_operational_states_select on public.tenant_operational_states
  for select to authenticated using (tenant_id in (select public.my_tenant_ids()));

create table public.tenant_operational_state_events (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  state_code   text not null references public.ng_states (code) on delete restrict,
  app_enabled  boolean not null,
  web_enabled  boolean not null,
  decision_id  uuid not null,
  changed_by   uuid not null references public.profiles (id) on delete restrict,
  changed_at   timestamptz not null default now(),
  foreign key (tenant_id, decision_id) references public.contact_report_decisions (tenant_id, id) on delete restrict
);
alter table public.tenant_operational_state_events enable row level security;
create index idx_tenant_operational_state_events_tenant on public.tenant_operational_state_events (tenant_id, state_code, changed_at);
create index idx_tenant_operational_state_events_decision on public.tenant_operational_state_events (tenant_id, decision_id);
create index idx_tenant_operational_state_events_changed_by on public.tenant_operational_state_events (changed_by);
create index idx_tenant_operational_state_events_state_code on public.tenant_operational_state_events (state_code);
create trigger tenant_operational_state_events_no_change before update or delete on public.tenant_operational_state_events
  for each row execute function public.operational_state_events_insert_only();
create trigger tenant_operational_state_events_no_truncate before truncate on public.tenant_operational_state_events
  for each statement execute function public.operational_state_events_insert_only();
revoke all on public.tenant_operational_state_events from anon, authenticated, service_role;
grant select on public.tenant_operational_state_events to authenticated;
create policy tenant_operational_state_events_select on public.tenant_operational_state_events
  for select to authenticated using (tenant_id in (select public.my_tenant_ids()));

-- RTM-core equivalent of monvelo_tenant_has_csm (the 045 boundary)
create function public.tenant_has_csm(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.tenant_users tu
                  where tu.tenant_id = p_tenant_id
                    and tu.role = 'CLIENT_SERVICE_MANAGER' and tu.status = 'ACTIVE');
$$;
revoke all on function public.tenant_has_csm(uuid) from public, anon, authenticated, service_role;

-- effective rule: the platform switch AND the brand's opt-in, per channel
create function public.tenant_state_app_operational(p_tenant_id uuid, p_state_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.state_app_operational(p_state_code)
     and coalesce((select t.app_enabled from public.tenant_operational_states t
                    where t.tenant_id = p_tenant_id and t.state_code = p_state_code), false);
$$;
revoke all on function public.tenant_state_app_operational(uuid, text) from public, anon;
grant execute on function public.tenant_state_app_operational(uuid, text) to authenticated, service_role;

create function public.tenant_state_web_operational(p_tenant_id uuid, p_state_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.state_web_operational(p_state_code)
     and coalesce((select t.web_enabled from public.tenant_operational_states t
                    where t.tenant_id = p_tenant_id and t.state_code = p_state_code), false);
$$;
revoke all on function public.tenant_state_web_operational(uuid, text) from public, anon;
grant execute on function public.tenant_state_web_operational(uuid, text) to authenticated, service_role;

create function public.set_tenant_operational_state(
  p_idempotency_key uuid, p_state_code text, p_app_enabled boolean, p_web_enabled boolean, p_decision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_state  public.ng_states;
  v_plat   public.operational_states;
  v_before public.tenant_operational_states;
  v_after  public.tenant_operational_states;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_tenant_operational_state',
    jsonb_build_object('state_code', p_state_code, 'app_enabled', p_app_enabled,
                       'web_enabled', p_web_enabled, 'decision_id', p_decision_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_me.role <> 'CLIENT_SERVICE_MANAGER' and public.tenant_has_csm(v_me.tenant_id) then
    raise exception 'the states a brand distributes in are set by the client service manager' using errcode = '42501';
  end if;
  if p_app_enabled is null or p_web_enabled is null then
    raise exception 'both the app and the web switch are required' using errcode = 'P0001';
  end if;
  select * into v_state from public.ng_states where code = p_state_code;
  if not found then
    raise exception 'unknown state' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'DISTRIBUTION');

  -- opting in needs the platform switch for that channel; opting out is always allowed
  select * into v_plat from public.operational_states where state_code = p_state_code;
  if (p_app_enabled and not v_plat.app_enabled) or (p_web_enabled and not v_plat.web_enabled) then
    raise exception 'Teafair is not operating in % on this channel yet', v_state.name using errcode = 'P0001';
  end if;

  select * into v_before from public.tenant_operational_states
   where tenant_id = v_me.tenant_id and state_code = p_state_code for update;

  insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id, updated_by)
  values (v_me.tenant_id, p_state_code, p_app_enabled, p_web_enabled, p_decision_id, v_me.profile_id)
  on conflict (tenant_id, state_code) do update
    set app_enabled = excluded.app_enabled, web_enabled = excluded.web_enabled,
        decision_id = excluded.decision_id, updated_by = excluded.updated_by, updated_at = now()
  returning * into v_after;

  insert into public.tenant_operational_state_events (tenant_id, state_code, app_enabled, web_enabled, decision_id, changed_by)
  values (v_me.tenant_id, p_state_code, p_app_enabled, p_web_enabled, p_decision_id, v_me.profile_id);

  perform public.write_audit(v_me.tenant_id, 'set_tenant_operational_state', 'tenant_operational_states',
                             p_state_code, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'state_code', p_state_code, 'app_enabled', v_after.app_enabled, 'web_enabled', v_after.web_enabled));
end;
$$;
revoke all on function public.set_tenant_operational_state(uuid, text, boolean, boolean, uuid) from public, anon;
grant execute on function public.set_tenant_operational_state(uuid, text, boolean, boolean, uuid) to authenticated;

-- refuses new app work in a territory whose state is off (P0001)
create function public.assert_state_app_operational(p_tenant_id uuid, p_territory_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_state text := public.territory_state_code(p_tenant_id, p_territory_id);
begin
  if v_state is null or not public.tenant_state_app_operational(p_tenant_id, v_state) then
    raise exception 'Teafair is not operating in % yet',
      coalesce((select s.name from public.ng_states s where s.code = v_state), 'this state')
      using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.assert_state_app_operational(uuid, uuid) from public, anon, authenticated, service_role;

-- ── set_state_operational ───────────────────────────────────────────────
create function public.set_state_operational(
  p_idempotency_key uuid, p_state_code text, p_app_enabled boolean, p_web_enabled boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_before public.operational_states;
  v_after  public.operational_states;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_state_operational',
    jsonb_build_object('state_code', p_state_code, 'app_enabled', p_app_enabled,
                       'web_enabled', p_web_enabled, 'reason', v_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_reason = '' then
    raise exception 'a reason is required' using errcode = 'P0001';
  end if;
  if p_app_enabled is null or p_web_enabled is null then
    raise exception 'both the app and the web switch are required' using errcode = 'P0001';
  end if;
  select * into v_before from public.operational_states where state_code = p_state_code for update;
  if not found then
    raise exception 'unknown state' using errcode = 'P0001';
  end if;

  update public.operational_states
     set app_enabled = p_app_enabled, web_enabled = p_web_enabled,
         updated_by = v_actor, updated_at = now()
   where state_code = p_state_code
  returning * into v_after;

  insert into public.operational_state_events (state_code, app_enabled, web_enabled, changed_by, reason)
  values (p_state_code, p_app_enabled, p_web_enabled, v_actor, v_reason);

  perform public.write_audit(null, 'set_state_operational', 'operational_states', p_state_code,
                             to_jsonb(v_before), to_jsonb(v_after) || jsonb_build_object('reason', v_reason),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'state_code', p_state_code, 'app_enabled', v_after.app_enabled, 'web_enabled', v_after.web_enabled));
end;
$$;
revoke all on function public.set_state_operational(uuid, text, boolean, boolean, text) from public, anon;
grant execute on function public.set_state_operational(uuid, text, boolean, boolean, text) to authenticated;


-- the filing RPC accepts the DISTRIBUTION subject (recreated from the live definition)
create or replace function public.file_contact_report(p_idempotency_key uuid, p_report jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me         public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior      jsonb;
  v_met_at     timestamptz;
  v_channel    text;
  v_summary    text;
  v_attendees  jsonb;
  v_supersedes uuid;
  v_decisions  jsonb;
  v_recipients jsonb;
  v_clean      jsonb := '[]'::jsonb;
  v_hints      jsonb := '[]'::jsonb;
  v_item       jsonb;
  v_c          jsonb;
  v_a          jsonb;
  v_report     public.contact_reports;
  v_rid        uuid;
  v_did        uuid;
  v_ids        uuid[] := '{}';
  v_seq        integer := 0;
  v_subjects   jsonb := '[]'::jsonb;
  v_n          integer;
begin
  if p_report is null or jsonb_typeof(p_report) <> 'object' then
    raise exception 'the report is required' using errcode = 'P0001';
  end if;

  -- shape checks (a bad value is P0001 before anything is written)
  begin
    v_met_at := (p_report ->> 'met_at')::timestamptz;
  exception when others then
    raise exception 'met_at must be a timestamp' using errcode = 'P0001';
  end;
  if v_met_at is null or v_met_at > now() then
    raise exception 'met_at must be a past time' using errcode = 'P0001';
  end if;
  v_channel := p_report ->> 'channel';
  if v_channel is null or v_channel not in ('MEETING', 'CALL', 'VIDEO', 'MESSAGE') then
    raise exception 'channel must be MEETING, CALL, VIDEO or MESSAGE' using errcode = 'P0001';
  end if;
  v_summary := btrim(coalesce(p_report ->> 'summary', ''));
  if length(v_summary) not between 1 and 4000 then
    raise exception 'the summary must be 1 to 4000 characters' using errcode = 'P0001';
  end if;
  v_attendees := p_report -> 'attendees';
  if v_attendees is null or jsonb_typeof(v_attendees) <> 'array'
     or jsonb_array_length(v_attendees) not between 1 and 30 then
    raise exception 'list 1 to 30 attendees' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_attendees) loop
    if jsonb_typeof(v_item) <> 'object'
       or length(btrim(coalesce(v_item ->> 'name', ''))) not between 1 and 200
       or coalesce(v_item ->> 'side', '') not in ('TEAFAIR', 'TENANT') then
      raise exception 'each attendee needs a name and a side of TEAFAIR or TENANT' using errcode = 'P0001';
    end if;
    v_a := coalesce(v_a, '[]'::jsonb)
           || jsonb_build_object('name', btrim(v_item ->> 'name'), 'side', v_item ->> 'side');
  end loop;
  v_attendees := v_a;

  begin
    v_supersedes := nullif(p_report ->> 'supersedes_id', '')::uuid;
  exception when others then
    raise exception 'supersedes_id must be a report id' using errcode = 'P0001';
  end;

  v_decisions := coalesce(p_report -> 'decisions', '[]'::jsonb);
  if jsonb_typeof(v_decisions) <> 'array' or jsonb_array_length(v_decisions) > 50 then
    raise exception 'a report records at most 50 decisions' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_decisions) loop
    if jsonb_typeof(v_item) <> 'object'
       or coalesce(v_item ->> 'subject', '') not in ('BRAND_TERMS', 'MONVELO_SETTINGS', 'FEES', 'CATALOGUE', 'STOCK', 'DISTRIBUTION', 'OTHER')
       or length(btrim(coalesce(v_item ->> 'text', ''))) not between 1 and 2000 then
      raise exception 'each decision needs a subject and 1 to 2000 characters of text' using errcode = 'P0001';
    end if;
  end loop;

  v_recipients := p_report -> 'recipients';
  if v_recipients is null or jsonb_typeof(v_recipients) <> 'array' or jsonb_array_length(v_recipients) < 1 then
    raise exception 'a contact report copies at least one tenant contact' using errcode = 'P0001';
  end if;
  if jsonb_array_length(v_recipients) > 20 then
    raise exception 'a contact report copies at most 20 contacts' using errcode = 'P0001';
  end if;
  for v_item in select * from jsonb_array_elements(v_recipients) loop
    v_c := public.contact_report_recipient_clean(v_item);
    v_clean := v_clean || v_c;
    v_hints := v_hints || (v_c - 'address');
  end loop;

  -- the stored request carries hints, never addresses
  v_prior := public.idempotency_begin(p_idempotency_key, 'file_contact_report',
    jsonb_build_object('met_at', v_met_at, 'channel', v_channel, 'attendees', v_attendees,
                       'summary', v_summary, 'supersedes_id', v_supersedes,
                       'decisions', v_decisions, 'recipients', v_hints));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_supersedes is not null then
    perform 1 from public.contact_reports r
     where r.id = v_supersedes and r.tenant_id = v_me.tenant_id
       for update;
    if not found or exists (select 1 from public.contact_reports r where r.supersedes_id = v_supersedes) then
      raise exception 'only the current version of a report can be corrected' using errcode = 'P0001';
    end if;
  end if;

  insert into public.contact_reports (tenant_id, reference, met_at, channel, attendees, summary,
                                      filed_by, supersedes_id)
  values (v_me.tenant_id, public.contact_report_draw_reference(), v_met_at, v_channel, v_attendees,
          v_summary, v_me.profile_id, v_supersedes)
  returning * into v_report;

  for v_item in select * from jsonb_array_elements(v_decisions) loop
    v_seq := v_seq + 1;
    insert into public.contact_report_decisions (tenant_id, report_id, seq, subject, decision_text)
    values (v_me.tenant_id, v_report.id, v_seq, v_item ->> 'subject', btrim(v_item ->> 'text'))
    returning id into v_did;
    v_ids := v_ids || v_did;
    v_subjects := v_subjects || to_jsonb(v_item ->> 'subject');
  end loop;

  for v_item in select * from jsonb_array_elements(v_clean) loop
    insert into public.contact_report_recipients (tenant_id, report_id, name, channel, address, address_hint)
    values (v_me.tenant_id, v_report.id, v_item ->> 'name', v_item ->> 'channel',
            v_item ->> 'address', v_item ->> 'address_hint')
    returning id into v_rid;
    insert into public.contact_report_deliveries (tenant_id, report_id, recipient_id, channel)
    values (v_me.tenant_id, v_report.id, v_rid, v_item ->> 'channel');
  end loop;
  select count(*) into v_n from public.contact_report_deliveries d where d.report_id = v_report.id;

  perform public.write_audit(v_me.tenant_id, 'file_contact_report', 'contact_reports', v_report.id::text, null,
                             jsonb_build_object('reference', v_report.reference, 'channel', v_channel,
                                                'supersedes_id', v_supersedes,
                                                'decision_subjects', v_subjects, 'recipients', v_hints),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'report_id', v_report.id, 'reference', v_report.reference,
    'decision_ids', to_jsonb(v_ids), 'deliveries_pending', v_n));
end;
$function$

;

-- ── enforcement on new work: recreated from the live definitions ────────
create or replace function public.web_route_try(p_tenant_id uuid, p_code web_referral_codes, p_lga_id uuid)
 RETURNS web_route
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_coded      boolean := p_code.id is not null;
  v_state      text;
  v_holder     public.tenant_users;
  v_terminal_t uuid;
  v_territory  uuid;
  v_zone       uuid;
  v_warehouse  uuid;
  v_acct       uuid;
  v_r          public.web_route;
begin
  select state_code into v_state from public.ng_lgas where id = p_lga_id;

  -- A6 §18.4: never route into a state that is not switched on for the web
  if v_state is not null and not public.tenant_state_web_operational(p_tenant_id, v_state) then
    return v_r;
  end if;

  -- 1. territory
  if v_coded then
    select * into v_holder from public.tenant_users
     where tenant_id = p_tenant_id and profile_id = p_code.agent_id and status = 'ACTIVE';
    if p_code.venue_id is not null then
      select territory_id into v_terminal_t from public.web_pos_venues
       where tenant_id = p_tenant_id and id = p_code.venue_id;
    end if;
    v_territory := coalesce(v_terminal_t, v_holder.territory_id);
  end if;
  if v_territory is null and v_state is not null then
    select territory_id into v_territory from public.territory_coverage
     where tenant_id = p_tenant_id and state_code = v_state and lga_id = p_lga_id;
    if v_territory is null then
      select territory_id into v_territory from public.territory_coverage
       where tenant_id = p_tenant_id and state_code = v_state and lga_id is null;
    end if;
  end if;

  -- 2. warehouse
  select coalesce(
           (select t.web_fulfilment_warehouse_id from public.territories t
             where t.tenant_id = p_tenant_id and t.id = v_territory),
           (select s.web_default_warehouse_id from public.tenant_settings s
             where s.tenant_id = p_tenant_id))
    into v_warehouse;

  -- 3. accountable person; every candidate must be an ACTIVE member
  if v_coded then
    if v_holder.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
      v_acct := v_holder.profile_id;
    else
      select tu.profile_id into v_acct
        from public.territories t
        join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                   and tu.status = 'ACTIVE'
       where t.tenant_id = p_tenant_id and t.id = v_territory;
    end if;
  else
    select tu.profile_id into v_acct
      from public.territories t
      join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                 and tu.status = 'ACTIVE'
     where t.tenant_id = p_tenant_id and t.id = v_territory;
    if v_acct is null then
      select zone_id into v_zone from public.territories
       where tenant_id = p_tenant_id and id = v_territory;
      select tu.profile_id into v_acct
        from public.zones z
        join public.tenant_users tu on tu.tenant_id = z.tenant_id and tu.profile_id = z.zsm_id
                                   and tu.status = 'ACTIVE'
       where z.tenant_id = p_tenant_id and z.id = v_zone;
    end if;
    if v_acct is null then
      select tu.profile_id into v_acct
        from public.tenant_settings s
        join public.tenant_users tu on tu.tenant_id = s.tenant_id and tu.profile_id = s.web_default_agent_id
                                   and tu.status = 'ACTIVE'
       where s.tenant_id = p_tenant_id;
    end if;
  end if;

  v_r.territory_id := v_territory;
  v_r.warehouse_id := v_warehouse;
  v_r.accountable_id := v_acct;
  return v_r;
end;
$function$

;

create or replace function public.place_web_order(p_idempotency_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb, p_payment_route text, p_expected_total numeric, p_checkout jsonb, p_lga_id uuid, p_accepted_refund_policy boolean, p_policy_version_tag text, p_client_ip inet, p_phone_verification_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_prior       jsonb;
  v_code        public.web_referral_codes;
  v_cart        jsonb;
  v_total       numeric(15,2);
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');
  v_terminal    public.web_pos_venues;
  v_route       public.web_route;  -- D1
  v_split       jsonb;             -- D1
  v_ref         text;
  v_order       public.orders;
  v_policy      public.refund_policies;          -- A5
  v_verif       public.web_phone_verifications;  -- A5
  v_now         timestamptz := now();
  v_state_code  text;
  v_state_name  text;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total,
                       'lga_id', p_lga_id));  -- D1
  -- A5: the verification token and the client IP are left out of the request
  -- hash on purpose (as A3 leaves out its secret): a replay carries a token
  -- that is already consumed, and neither belongs in idempotency_logs.
  if v_prior is not null then
    return v_prior;  -- a replay keeps the original order and its original consent
  end if;

  -- A5 §3.6, §3.3: consent first, then the policy it was given against
  if p_accepted_refund_policy is distinct from true then
    raise exception 'You must accept the refund policy to place an order.' using errcode = 'P0001';
  end if;
  select * into v_policy from public.refund_policies where is_active;
  if not found or p_policy_version_tag is distinct from v_policy.version_tag then
    raise exception 'The refund policy has changed. Please review it and try again.' using errcode = 'P0001';
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_storefront_code(p_code);  -- D1: null or blank is codeless
  if p_payment_route = 'POS_AGENT' and v_code.venue_id is null then
    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';
  end if;

  -- A6 §18.4: new web orders only where the platform and the brand are both switched on
  select s.code, s.name into v_state_code, v_state_name
    from public.ng_lgas l join public.ng_states s on s.code = l.state_code
   where l.id = p_lga_id;
  if found and not public.tenant_state_web_operational(v_code.tenant_id, v_state_code) then
    raise exception 'we do not deliver to % yet', v_state_name using errcode = 'P0001';
  end if;

  v_cart := public.web_price_cart(v_code, p_items);
  v_total := (v_cart ->> 'total')::numeric;
  if p_expected_total is distinct from v_total then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A5 §3.1: every line must be in a category the active policy covers
  if exists (select 1 from jsonb_array_elements(v_cart -> 'lines') l
               join public.central_products cp
                 on cp.tenant_id = v_code.tenant_id and cp.sku_code = l ->> 'sku_code'
              where not public.web_category_sellable(cp.sale_category)) then
    raise exception 'This product is not available to order yet.' using errcode = 'P0001';
  end if;

  if v_name is null then
    raise exception 'your name is required' using errcode = 'P0001';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'the email address is not valid' using errcode = 'P0001';
  end if;
  if v_address is null then
    raise exception 'a delivery address is required' using errcode = 'P0001';
  end if;
  if p_payment_route = 'PAYSTACK_WEB' and (
       coalesce(p_checkout ->> 'reference', '') = '' or coalesce(p_checkout ->> 'authorization_url', '') = '') then
    raise exception 'checkout details are missing' using errcode = 'P0001';
  end if;

  -- D1 Decision 6: the split Paystack was initialised with must be this
  -- quote split, or both JSON null. A missing key is not JSON null.
  v_split := nullif(v_cart -> 'split', 'null'::jsonb);
  if p_payment_route = 'PAYSTACK_WEB' and (p_checkout -> 'split') is distinct from
       (case when v_split is null then 'null'::jsonb
             else jsonb_build_object('subaccount_code', v_split -> 'subaccount_code',
                                     'commission_bps',  v_split -> 'commission_bps',
                                     'partner_share',   v_split -> 'partner_share') end) then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- A5 §3.5: the buyer proved this number on WhatsApp. The token is bound to
  -- the phone, single use and short lived; the row is locked and consumed.
  select * into v_verif from public.web_phone_verifications
   where token_hash = encode(extensions.digest(coalesce(p_phone_verification_token, ''), 'sha256'), 'hex')
     and verified_at is not null and consumed_at is null
     and token_expires_at > v_now and phone = v_phone
   for update;
  if not found then
    raise exception 'Please verify your WhatsApp number again.' using errcode = 'P0001';
  end if;
  update public.web_phone_verifications set consumed_at = v_now where id = v_verif.id;

  -- D1 §4: territory, warehouse and accountable person, or a refusal
  v_route := public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  if v_code.venue_id is not null then
    select * into v_terminal from public.web_pos_venues
     where tenant_id = v_code.tenant_id and id = v_code.venue_id;
  end if;

  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform
  loop
    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                         from generate_series(1, 6));
    exit when not exists (select 1 from public.orders where public_reference = v_ref);
  end loop;

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, transport_fare, status,
                             referral_code_id, attributed_agent_id, attributed_venue_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id,
                             policy_version_tag, policy_accepted_at)
  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric,
          (v_cart ->> 'transport_fare')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.venue_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref,
          p_lga_id, v_route.territory_id, v_route.warehouse_id,
          v_policy.version_tag, v_now)
  returning * into v_order;

  -- A2; D1: the contacts territory is the order territory
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address,
                                     consent_ip, phone_verified_at, phone_verified_channel)
  values (v_order.id, v_order.tenant_id, v_route.territory_id, v_name, v_phone, v_email, v_address,
          p_client_ip, v_verif.verified_at, 'WHATSAPP');  -- A5: the IP lives on A2's table only

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, web_pos_partner_id, web_pos_venue_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload,
                                 split_subaccount_code, split_bps, split_amount)
    values (v_order.tenant_id, v_order.id, v_route.accountable_id, v_terminal.partner_id, v_code.venue_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')),
            v_split ->> 'subaccount_code', (v_split ->> 'commission_bps')::integer,
            (v_split ->> 'partner_share')::numeric);
  end if;

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null),
                               -- A5: the consent and the fact of verification, never the IP
                               'policy_version_tag', v_order.policy_version_tag,
                               'policy_accepted_at', v_order.policy_accepted_at,
                               'phone_verified', true),
                             p_idempotency_key, 'WEB', v_route.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'transport_fare', (v_cart ->> 'transport_fare')::numeric,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$function$

;

create or replace function public.storefront_locations(p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code  public.web_referral_codes := public.web_storefront_code(p_code);
  v_coded public.web_referral_codes;
begin
  if v_code.id is not null then
    v_coded := v_code;
  end if;
  return (
    with lga as (
      select l.state_code, l.id, l.name,
             (r.territory_id is not null and r.warehouse_id is not null and r.accountable_id is not null) as deliverable
        from public.ng_lgas l
        cross join lateral public.web_route_try(v_code.tenant_id, v_coded, l.id) r
       where public.tenant_state_web_operational(v_code.tenant_id, l.state_code)
    )
    select jsonb_build_object('states', coalesce(jsonb_agg(jsonb_build_object(
             'code', s.code, 'name', s.name,
             'lgas', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'deliverable', g.deliverable)
                                       order by g.name)
                        from lga g where g.state_code = s.code))
           order by s.name), '[]'::jsonb))
      from public.ng_states s
     where public.tenant_state_web_operational(v_code.tenant_id, s.code));
end;
$function$

;

create or replace function public.enrol_monvelo_shop(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_version      constant text    := 'MV-SHARE-2026-10';
  c_max_attempts constant integer := 5;
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_ch      public.monvelo_consent_challenges;
  v_before  public.monvelo_shop_enrolments;
  v_after   public.monvelo_shop_enrolments;
  v_shopcode text;
  v_terr     uuid;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'enrol_monvelo_shop',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_ch from public.monvelo_consent_challenges where id = p_challenge_id for update;
  if not found or v_ch.tenant_id <> v_me.tenant_id then
    raise exception 'unknown consent code request' using errcode = '42501';
  end if;
  if v_ch.issued_by <> v_me.profile_id then
    raise exception 'this consent code was requested by someone else' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the consent code must be 6 digits' using errcode = 'P0001';
  end if;

  -- concurrent first enrolments of one shop serialise here, so the second
  -- sees the first row instead of hitting 23505
  perform pg_advisory_xact_lock(hashtextextended('enrol_monvelo_shop:' || v_ch.tenant_id || ':' || v_ch.shop_id, 0));
  select * into v_before from public.monvelo_shop_enrolments e
   where e.tenant_id = v_ch.tenant_id and e.shop_id = v_ch.shop_id for update;

  -- this very challenge already enrolled the shop: return the existing row
  if v_ch.consumed_at is not null then
    if v_before.shop_id is not null and v_before.status = 'ACTIVE' and v_before.consent_challenge_id = v_ch.id then
      select shop_code into v_shopcode from public.retail_shops where id = v_ch.shop_id;
      return public.idempotency_complete(p_idempotency_key,
        jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
    end if;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'INVALID'));
  end if;
  -- A6 §18.4: new enrolments only where Teafair operates (the area's state)
  select a.territory_id into v_terr from public.areas a where a.id = v_ch.area_id;
  perform public.assert_state_app_operational(v_ch.tenant_id, v_terr);
  if v_ch.failed_attempts >= c_max_attempts then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'LOCKED'));
  end if;
  if v_ch.expires_at <= now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'EXPIRED'));
  end if;

  if v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_consent_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(v_ch.tenant_id, 'MONVELO_CONSENT_FAILED', 'monvelo_consent_challenges', v_ch.id::text,
                               null, jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'shop_id', v_ch.shop_id),
                               p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false,
      'reason', case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end));
  end if;

  -- the right code
  update public.monvelo_consent_challenges set consumed_at = now() where id = v_ch.id;
  if v_before.shop_id is not null and v_before.status in ('ACTIVE', 'SUSPENDED') then
    -- already enrolled by another route: keep the existing row
    v_after := v_before;
  elsif v_before.shop_id is not null then
    -- WITHDRAWN: a fresh code brings it back
    update public.monvelo_shop_enrolments
       set status = 'ACTIVE', withdrawn_at = null, area_id = v_ch.area_id, recruited_by = v_ch.issued_by,
           consent_at = clock_timestamp(), consent_version = c_version, consent_challenge_id = v_ch.id
     where tenant_id = v_ch.tenant_id and shop_id = v_ch.shop_id
    returning * into v_after;
  else
    insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at,
                                                consent_version, consent_challenge_id, status)
    values (v_ch.tenant_id, v_ch.shop_id, v_ch.area_id, v_ch.issued_by, clock_timestamp(), c_version, v_ch.id, 'ACTIVE')
    returning * into v_after;
  end if;
  v_shopcode := public.monvelo_assign_shop_code(v_ch.shop_id);

  perform public.write_audit(v_ch.tenant_id, 'enrol_monvelo_shop', 'monvelo_shop_enrolments', v_ch.shop_id::text,
                             case when v_before.shop_id is null then null else to_jsonb(v_before) end,
                             to_jsonb(v_after) || jsonb_build_object('shop_code', v_shopcode), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
end;
$function$

;

create or replace function public.set_monvelo_supply_day(p_idempotency_key uuid, p_area_id uuid, p_day_of_week integer, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_area   public.areas;
  v_before public.monvelo_supply_days;
  v_after  public.monvelo_supply_days;
begin
  select * into v_area from public.areas
   where id = p_area_id and tenant_id = v_me.tenant_id;
  if not found or v_me.role <> 'TM' or v_area.territory_id is distinct from v_me.territory_id then
    raise exception 'supply days are set by the TM of the area''s territory' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_supply_day',
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', p_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_day_of_week is null or p_day_of_week not between 1 and 7 or p_active is null then
    raise exception 'a weekday from 1 (Monday) to 7 and an active flag are required' using errcode = 'P0001';
  end if;
  -- A6 §18.4: new supply days only where Teafair operates
  perform public.assert_state_app_operational(v_me.tenant_id, v_area.territory_id);

  select * into v_before from public.monvelo_supply_days
   where tenant_id = v_me.tenant_id and area_id = p_area_id and day_of_week = p_day_of_week
   for update;

  insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
  values (v_me.tenant_id, p_area_id, p_day_of_week, p_active, v_me.profile_id)
  on conflict (tenant_id, area_id, day_of_week) do update
    set active = excluded.active, set_by = excluded.set_by
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_supply_day', 'monvelo_supply_days',
                             p_area_id::text || ':' || p_day_of_week::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', v_after.active));
end;
$function$

;

create or replace function public.pledge_monvelo_funds(p_idempotency_key uuid, p_agent_id uuid, p_area_id uuid, p_supply_date date, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_status  text;
  v_area    public.areas;
  v_before  public.monvelo_pledges;
  v_after   public.monvelo_pledges;
  v_amount  numeric(15,2);
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_agent_id is null or not exists (select 1 from public.my_monvelo_agent_ids() m(id) where m.id = p_agent_id) then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'pledge_monvelo_funds',
    jsonb_build_object('agent_id', p_agent_id, 'area_id', p_area_id,
                       'supply_date', p_supply_date, 'amount', p_amount));
  if v_prior is not null then
    return v_prior;
  end if;

  select a.status into v_status from public.monvelo_agents a where a.id = p_agent_id;
  if v_status is distinct from 'ACTIVE' then
    raise exception 'the agent is not active' using errcode = 'P0001';
  end if;

  if p_amount is null or p_amount <= 0 or p_supply_date is null or p_area_id is null then
    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';
  end if;

  select * into v_area from public.areas where id = p_area_id;
  if not found then
    raise exception 'area not found' using errcode = 'P0001';
  end if;
  if not coalesce((select ts.enabled from public.monvelo_tenant_settings ts
                    where ts.tenant_id = v_area.tenant_id), false) then
    raise exception 'Monvelo is not enabled for this area''s tenant' using errcode = 'P0001';
  end if;

  -- A6 §18.4: new pledges only where Teafair operates
  perform public.assert_state_app_operational(v_area.tenant_id, v_area.territory_id);

  if p_supply_date < public.monvelo_today()
     or not exists (select 1 from public.monvelo_supply_days d
                     where d.tenant_id = v_area.tenant_id and d.area_id = p_area_id
                       and d.day_of_week = extract(isodow from p_supply_date)::int and d.active) then
    raise exception 'that date is not a supply day for this area' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_pledges
   where agent_id = p_agent_id and tenant_id = v_area.tenant_id
     and area_id = p_area_id and supply_date = p_supply_date
   for update;

  if not found then
    insert into public.monvelo_pledges (tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
    values (v_area.tenant_id, p_agent_id, p_area_id, p_supply_date, v_amount, v_amount, v_uid)
    returning * into v_after;
  else
    if v_before.remaining + (v_amount - v_before.amount) < 0 then
      raise exception 'a pledge cannot drop below what is already funded' using errcode = 'P0001';
    end if;
    update public.monvelo_pledges
       set amount = v_amount,
           remaining = v_before.remaining + (v_amount - v_before.amount),
           pledged_by = v_uid
     where id = v_before.id
    returning * into v_after;
  end if;

  perform public.write_audit(v_area.tenant_id, 'pledge_monvelo_funds', 'monvelo_pledges', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('pledge_id', v_after.id, 'amount', v_after.amount, 'remaining', v_after.remaining));
end;
$function$

;

