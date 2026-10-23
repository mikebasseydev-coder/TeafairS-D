-- Addendum A4 §3 — internal staff messaging: channels (direct chats carry a
-- sorted participant pair), messages and per-person read state. Who can read
-- a channel is derived live from tenant_users by one helper,
-- my_chat_channel_ids(); membership is never stored. Group channel rows
-- (territory, zone, announcement) are backfilled and created by insert
-- triggers. Every write is a later RPC.

-- ── chat_channels ───────────────────────────────────────────────────────
create table public.chat_channels (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  channel_type     text not null check (channel_type in ('DIRECT', 'TERRITORY', 'ZONE', 'ANNOUNCEMENT')),
  territory_id     uuid,
  zone_id          uuid,
  direct_low_id    uuid references public.profiles (id) on delete restrict,
  direct_high_id   uuid references public.profiles (id) on delete restrict,
  last_message_at  timestamptz,
  created_at       timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  foreign key (tenant_id, zone_id)      references public.zones (tenant_id, id) on delete restrict,
  -- each type carries exactly its own columns
  constraint chat_channels_type_columns check (
    case channel_type
      when 'DIRECT' then territory_id is null and zone_id is null
                         and direct_low_id is not null and direct_high_id is not null
      when 'TERRITORY' then territory_id is not null and zone_id is null
                         and direct_low_id is null and direct_high_id is null
      when 'ZONE' then zone_id is not null and territory_id is null
                         and direct_low_id is null and direct_high_id is null
      when 'ANNOUNCEMENT' then territory_id is null and zone_id is null
                         and direct_low_id is null and direct_high_id is null
    end),
  -- a direct chat stores its pair sorted, so one pair has one channel
  constraint chat_channels_direct_sorted check (direct_low_id < direct_high_id)
);
alter table public.chat_channels enable row level security;
create unique index chat_channels_one_territory    on public.chat_channels (tenant_id, territory_id)
  where channel_type = 'TERRITORY';
create unique index chat_channels_one_zone         on public.chat_channels (tenant_id, zone_id)
  where channel_type = 'ZONE';
create unique index chat_channels_one_announcement on public.chat_channels (tenant_id)
  where channel_type = 'ANNOUNCEMENT';
create unique index chat_channels_one_direct       on public.chat_channels (tenant_id, direct_low_id, direct_high_id)
  where channel_type = 'DIRECT';
-- FK indexes (the partial uniques do not serve FK checks) and the direct
-- lookups my_chat_channel_ids() makes from either side of the pair
create index idx_chat_channels_territory   on public.chat_channels (tenant_id, territory_id);
create index idx_chat_channels_zone        on public.chat_channels (tenant_id, zone_id);
create index idx_chat_channels_direct_low  on public.chat_channels (direct_low_id);
create index idx_chat_channels_direct_high on public.chat_channels (direct_high_id);

-- ── chat_messages ───────────────────────────────────────────────────────
create table public.chat_messages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete restrict,
  channel_id  uuid not null,
  sender_id   uuid not null references public.profiles (id) on delete restrict,
  body        text not null check (length(btrim(body)) between 1 and 2000),
  hidden_at   timestamptz,
  hidden_by   uuid references public.profiles (id) on delete restrict,
  created_at  timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  foreign key (tenant_id, channel_id) references public.chat_channels (tenant_id, id) on delete restrict
);
alter table public.chat_messages enable row level security;
create index idx_chat_messages_thread    on public.chat_messages (channel_id, created_at, id);
-- the per-sender throttle
create index idx_chat_messages_sender    on public.chat_messages (sender_id, created_at);
create index idx_chat_messages_channel   on public.chat_messages (tenant_id, channel_id);
create index idx_chat_messages_hidden_by on public.chat_messages (hidden_by);

-- ── chat_read_state ─────────────────────────────────────────────────────
create table public.chat_read_state (
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  channel_id    uuid not null,
  profile_id    uuid not null references public.profiles (id) on delete restrict,
  last_read_at  timestamptz not null,
  primary key (tenant_id, channel_id, profile_id),
  foreign key (tenant_id, channel_id) references public.chat_channels (tenant_id, id) on delete restrict
);
alter table public.chat_read_state enable row level security;
create index idx_chat_read_state_profile on public.chat_read_state (profile_id, channel_id);

-- ── internal helpers (no grant): the shared rules RLS and RPCs both use ──
-- §7.6: available = ACTIVE and holding a staff role in that tenant.
create or replace function public.chat_is_available(p_tenant uuid, p_profile uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.tenant_users tu
     where tu.tenant_id = p_tenant
       and tu.profile_id = p_profile
       and tu.status = 'ACTIVE'
       and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA'));
$$;
revoke all on function public.chat_is_available(uuid, uuid) from public, anon, authenticated, service_role;

-- §7.2: a ZSM's zone is tenant_users.zone_id; every other staff role's zone
-- is territories.zone_id through its territory_id. Null when unavailable.
create or replace function public.chat_staff_zone(p_tenant uuid, p_profile uuid)
returns uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select case when tu.role = 'ZSM' then tu.zone_id else t.zone_id end
    from public.tenant_users tu
    left join public.territories t on t.tenant_id = tu.tenant_id and t.id = tu.territory_id
   where tu.tenant_id = p_tenant
     and tu.profile_id = p_profile
     and tu.status = 'ACTIVE'
     and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA');
$$;
revoke all on function public.chat_staff_zone(uuid, uuid) from public, anon, authenticated, service_role;

-- ── the single source of truth for chat reads (§3.4, §7.1) ──────────────
-- For each of the caller's ACTIVE staff memberships (every tenant, like
-- my_tenant_ids()):
--   TERRITORY    own territory (TM, ASM, DSM, DSA); every territory of the
--                zone (ZSM)
--   ZONE         own zone (ZSM, and TM via its territory's zone)
--   ANNOUNCEMENT the tenant's stream
--   DIRECT       channels where the caller is one of the pair; the other
--                participant's status does not hide the history
create or replace function public.my_chat_channel_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  with me as (
    select tu.tenant_id, tu.profile_id, tu.role, tu.territory_id,
           public.chat_staff_zone(tu.tenant_id, tu.profile_id) as zone_id
      from public.tenant_users tu
     where tu.profile_id = (select auth.uid())
       and tu.status = 'ACTIVE'
       and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA')
  )
  -- TERRITORY: own room
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'TERRITORY' and c.territory_id = me.territory_id
   where me.role <> 'ZSM'
  union
  -- TERRITORY: a ZSM sees every room in the zone
  select c.id
    from me
    join public.territories t on t.tenant_id = me.tenant_id and t.zone_id = me.zone_id
    join public.chat_channels c
      on c.tenant_id = t.tenant_id and c.channel_type = 'TERRITORY' and c.territory_id = t.id
   where me.role = 'ZSM'
  union
  -- ZONE: the zone's ZSMs and TMs
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'ZONE' and c.zone_id = me.zone_id
   where me.role in ('ZSM', 'TM')
  union
  -- ANNOUNCEMENT: every staff member
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'ANNOUNCEMENT'
  union
  -- DIRECT: only the two participants
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'DIRECT' and c.direct_low_id = me.profile_id
  union
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'DIRECT' and c.direct_high_id = me.profile_id;
$$;
revoke all on function public.my_chat_channel_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_chat_channel_ids() to authenticated;

-- ── RLS and grants: SELECT only ─────────────────────────────────────────
-- default privileges grant SELECT on new tables to authenticated; restate
-- exactly what the app gets
revoke all on public.chat_channels, public.chat_messages, public.chat_read_state from anon, authenticated;
grant select on public.chat_channels, public.chat_messages, public.chat_read_state to authenticated;

create policy chat_channels_select_member on public.chat_channels
  for select to authenticated
  using (id in (select public.my_chat_channel_ids()));

create policy chat_messages_select_member on public.chat_messages
  for select to authenticated
  using (channel_id in (select public.my_chat_channel_ids()));

create policy chat_read_state_select_own on public.chat_read_state
  for select to authenticated
  using (channel_id in (select public.my_chat_channel_ids())
         and profile_id = (select auth.uid()));

-- ── group channels: one per territory, zone and tenant ──────────────────
-- These triggers maintain channel rows, never membership.
create or replace function public.chat_create_group_channel()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'territories' then
    insert into public.chat_channels (tenant_id, channel_type, territory_id)
    values (new.tenant_id, 'TERRITORY', new.id)
    on conflict do nothing;
  elsif tg_table_name = 'zones' then
    insert into public.chat_channels (tenant_id, channel_type, zone_id)
    values (new.tenant_id, 'ZONE', new.id)
    on conflict do nothing;
  elsif tg_table_name = 'tenants' then
    insert into public.chat_channels (tenant_id, channel_type)
    values (new.id, 'ANNOUNCEMENT')
    on conflict do nothing;
  end if;
  return null;
end;
$$;
revoke all on function public.chat_create_group_channel() from public, anon, authenticated, service_role;

create trigger territories_chat_channel after insert on public.territories
  for each row execute function public.chat_create_group_channel();
create trigger zones_chat_channel after insert on public.zones
  for each row execute function public.chat_create_group_channel();
create trigger tenants_chat_channel after insert on public.tenants
  for each row execute function public.chat_create_group_channel();

-- backfill: TEAFAIR and every other existing tenant, zone and territory
insert into public.chat_channels (tenant_id, channel_type)
select tn.id, 'ANNOUNCEMENT' from public.tenants tn
on conflict do nothing;
insert into public.chat_channels (tenant_id, channel_type, zone_id)
select z.tenant_id, 'ZONE', z.id from public.zones z
on conflict do nothing;
insert into public.chat_channels (tenant_id, channel_type, territory_id)
select t.tenant_id, 'TERRITORY', t.id from public.territories t
on conflict do nothing;

-- ── Realtime: RLS filters per subscriber; channels re-order inboxes ─────
alter publication supabase_realtime add table public.chat_messages, public.chat_channels;
