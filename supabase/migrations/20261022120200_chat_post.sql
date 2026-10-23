-- Addendum A4 §4.2–§4.5 — posting, read state and the inbox.
--   post_chat_message      writes a message, bumps the channel, marks it read
--                          for the sender and notifies (DIRECT: the other
--                          person; ANNOUNCEMENT: every available staff member
--                          but the sender; rooms never notify). Notification
--                          copy is fixed and never quotes the message.
--   mark_chat_read         moves a person's read marker forward only; not audited.
--   list_my_chat_channels  the inbox, computed from my_chat_channel_ids().
-- Audit after-images hold ids, never a message body.

create or replace function public.post_chat_message(
  p_idempotency_key uuid,
  p_channel_id uuid,
  p_body text
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
  v_ch      public.chat_channels;
  v_body    text := btrim(coalesce(p_body, ''));
  v_msg     public.chat_messages;
  v_other   uuid;
  v_payload jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'post_chat_message',
               jsonb_build_object('channel', p_channel_id, 'body', v_body));
  if v_prior is not null then return v_prior; end if;

  select c.* into v_ch from public.chat_channels c
   where c.id = p_channel_id
     and c.tenant_id = v_me.tenant_id
     and c.id in (select public.my_chat_channel_ids())
   for update;
  if not found then
    raise exception 'channel not found' using errcode = '42501';
  end if;

  if v_ch.channel_type = 'ANNOUNCEMENT' and v_me.role <> 'ZSM' then
    raise exception 'only zone managers may post announcements' using errcode = '42501';
  end if;

  if v_ch.channel_type = 'DIRECT' then
    v_other := case when v_ch.direct_low_id = v_me.profile_id
                    then v_ch.direct_high_id else v_ch.direct_low_id end;
    if not public.chat_is_available(v_me.tenant_id, v_other) then
      raise exception 'this person is no longer available' using errcode = 'P0001';
    end if;
  end if;

  if length(v_body) not between 1 and 2000 then
    raise exception 'a message must be 1 to 2000 characters' using errcode = 'P0001';
  end if;

  if (select count(*) from public.chat_messages m
       where m.tenant_id = v_me.tenant_id and m.sender_id = v_me.profile_id
         and m.created_at > clock_timestamp() - interval '1 minute') >= 20 then
    raise exception 'Too many messages. Please wait a moment.' using errcode = 'P0001';
  end if;

  insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
  values (v_me.tenant_id, v_ch.id, v_me.profile_id, v_body)
  returning * into v_msg;

  update public.chat_channels set last_message_at = v_msg.created_at where id = v_ch.id;

  insert into public.chat_read_state (tenant_id, channel_id, profile_id, last_read_at)
  values (v_me.tenant_id, v_ch.id, v_me.profile_id, v_msg.created_at)
  on conflict (tenant_id, channel_id, profile_id)
  do update set last_read_at = greatest(public.chat_read_state.last_read_at, excluded.last_read_at);

  v_payload := jsonb_build_object('channel_id', v_ch.id, 'message_id', v_msg.id);
  if v_ch.channel_type = 'DIRECT' then
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    values (v_me.tenant_id, v_other, 'CHAT_MESSAGE', 'New message', 'You have a new message.', v_payload);
  elsif v_ch.channel_type = 'ANNOUNCEMENT' then
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    select v_me.tenant_id, tu.profile_id, 'CHAT_ANNOUNCEMENT', 'Announcement',
           'There is a new announcement.', v_payload
      from public.tenant_users tu
     where tu.tenant_id = v_me.tenant_id
       and tu.status = 'ACTIVE'
       and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA')
       and tu.profile_id <> v_me.profile_id;
  end if;

  perform public.write_audit(v_me.tenant_id, 'post_chat_message', 'chat_messages', v_msg.id::text,
    null, jsonb_build_object('message_id', v_msg.id, 'channel_id', v_ch.id,
                             'channel_type', v_ch.channel_type), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('message_id', v_msg.id, 'created_at', v_msg.created_at));
end;
$$;
revoke all on function public.post_chat_message(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.post_chat_message(uuid, uuid, text) to authenticated;

create or replace function public.mark_chat_read(
  p_idempotency_key uuid,
  p_channel_id uuid,
  p_read_up_to timestamptz
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
  v_ch      public.chat_channels;
  v_last    timestamptz;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'mark_chat_read',
               jsonb_build_object('channel', p_channel_id, 'up_to', p_read_up_to));
  if v_prior is not null then return v_prior; end if;

  select c.* into v_ch from public.chat_channels c
   where c.id = p_channel_id
     and c.tenant_id = v_me.tenant_id
     and c.id in (select public.my_chat_channel_ids());
  if not found then
    raise exception 'channel not found' using errcode = '42501';
  end if;

  -- never beyond the present; clock_timestamp() because message times use it
  insert into public.chat_read_state (tenant_id, channel_id, profile_id, last_read_at)
  values (v_me.tenant_id, v_ch.id, v_me.profile_id, least(p_read_up_to, clock_timestamp()))
  on conflict (tenant_id, channel_id, profile_id)
  do update set last_read_at = greatest(public.chat_read_state.last_read_at, excluded.last_read_at)
  returning last_read_at into v_last;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('channel_id', v_ch.id, 'last_read_at', v_last));
end;
$$;
revoke all on function public.mark_chat_read(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.mark_chat_read(uuid, uuid, timestamptz) to authenticated;

-- §7.8: unread is capped at 100 per channel
create or replace function public.list_my_chat_channels()
returns setof jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'channel_id', c.id,
           'tenant_id', c.tenant_id,
           'channel_type', c.channel_type,
           'territory_id', c.territory_id,
           'zone_id', c.zone_id,
           'other_profile_id', case when c.channel_type = 'DIRECT'
              then case when c.direct_low_id = (select auth.uid())
                        then c.direct_high_id else c.direct_low_id end end,
           'last_message_at', c.last_message_at,
           'unread_count', (
             select count(*) from (
               select 1 from public.chat_messages m
                where m.channel_id = c.id
                  and m.sender_id <> (select auth.uid())
                  and m.created_at > coalesce(
                        (select rs.last_read_at from public.chat_read_state rs
                          where rs.tenant_id = c.tenant_id and rs.channel_id = c.id
                            and rs.profile_id = (select auth.uid())),
                        '-infinity'::timestamptz)
                limit 100) u))
    from public.chat_channels c
   where c.id in (select public.my_chat_channel_ids())
   order by c.last_message_at desc nulls last, c.id;
$$;
revoke all on function public.list_my_chat_channels() from public, anon, authenticated, service_role;
grant execute on function public.list_my_chat_channels() to authenticated;
