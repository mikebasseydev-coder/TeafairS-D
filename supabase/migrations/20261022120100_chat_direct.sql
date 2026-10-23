-- Addendum A4 §4.1 — direct chats. get_or_create_direct_channel opens (or
-- returns) the one channel for a pair of staff. Scope is symmetric:
--   * both share a territory_id; or
--   * one is a ZSM and the other works in that ZSM's zone; or
--   * both are TM or ZSM of the same zone.
-- Zones come from chat_staff_zone (§7.2). Scope is checked only when a
-- channel is created: an existing pair is returned even after one person has
-- moved, since its history is already theirs. Writes no audit row: audit_logs
-- is readable tenant-wide by TMs and ZSMs and would reveal who messages whom
-- (§7.9, user decision 2026-10-22).
create or replace function public.get_or_create_direct_channel(
  p_idempotency_key uuid,
  p_target_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['ZSM', 'TM', 'ASM', 'DSM', 'DSA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_target  public.tenant_users;
  v_my_zone uuid;
  v_their_zone uuid;
  v_low     uuid := least(v_me.profile_id, p_target_profile_id);
  v_high    uuid := greatest(v_me.profile_id, p_target_profile_id);
  v_id      uuid;
  v_created boolean;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'get_or_create_direct_channel',
               jsonb_build_object('target', p_target_profile_id));
  if v_prior is not null then return v_prior; end if;

  if p_target_profile_id = v_me.profile_id then
    raise exception 'you cannot message yourself' using errcode = 'P0001';
  end if;
  if not public.chat_is_available(v_me.tenant_id, p_target_profile_id) then
    raise exception 'that person is not available' using errcode = 'P0001';
  end if;

  -- an existing pair is reopened without the scope rule (§4.1)
  select c.id into v_id from public.chat_channels c
   where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
     and c.direct_low_id = v_low and c.direct_high_id = v_high;
  if found then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('channel_id', v_id, 'created', false));
  end if;

  select * into v_target from public.tenant_users tu
   where tu.tenant_id = v_me.tenant_id and tu.profile_id = p_target_profile_id and tu.status = 'ACTIVE';
  v_my_zone    := public.chat_staff_zone(v_me.tenant_id, v_me.profile_id);
  v_their_zone := public.chat_staff_zone(v_me.tenant_id, p_target_profile_id);

  if not (
       (v_me.territory_id is not null and v_me.territory_id = v_target.territory_id)
    or (v_me.role = 'ZSM' and v_their_zone is not null and v_their_zone = v_my_zone)
    or (v_target.role = 'ZSM' and v_my_zone is not null and v_my_zone = v_their_zone)
    or (v_me.role in ('TM', 'ZSM') and v_target.role in ('TM', 'ZSM')
        and v_my_zone is not null and v_my_zone = v_their_zone)
  ) then
    raise exception 'you may not message that person' using errcode = '42501';
  end if;

  insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values (v_me.tenant_id, 'DIRECT', v_low, v_high)
  on conflict (tenant_id, direct_low_id, direct_high_id) where channel_type = 'DIRECT' do nothing
  returning id into v_id;
  v_created := v_id is not null;

  -- lost a race with a concurrent create of the same pair
  if not v_created then
    select c.id into v_id from public.chat_channels c
     where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
       and c.direct_low_id = v_low and c.direct_high_id = v_high;
  end if;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('channel_id', v_id, 'created', v_created));
end;
$$;
revoke all on function public.get_or_create_direct_channel(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_or_create_direct_channel(uuid, uuid) to authenticated;
