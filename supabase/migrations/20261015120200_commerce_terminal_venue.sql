-- Addendum A1 §4.1 — set the venue a POS terminal sits in.
-- ZSM: any terminal in the tenant. TM: terminals in their own territory.
-- FINTECH_AGENT: their own terminals. The point must fall inside the
-- territory boundary when the territory has one.
create or replace function public.set_terminal_venue(
  p_idempotency_key  uuid,
  p_terminal_id      uuid,
  p_venue_channel    public.venue_channel_enum,
  p_venue_name       text,
  p_address_text     text,
  p_state            text,
  p_lga              text,
  p_latitude         double precision,
  p_longitude        double precision,
  p_operating_hours  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.fintech_terminals;
  v_after    public.fintech_terminals;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_terminal_venue',
    jsonb_build_object('terminal_id', p_terminal_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.fintech_terminals
   where id = p_terminal_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'FINTECH_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.fintech_terminals
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_terminal_venue', 'fintech_terminals', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('terminal_id', v_after.id));
end;
$$;

grant execute on function public.set_terminal_venue(uuid, uuid, public.venue_channel_enum, text, text, text, text,
                                                    double precision, double precision, jsonb) to authenticated;
