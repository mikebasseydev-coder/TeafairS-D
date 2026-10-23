-- Addendum A4 §4.4 — moderation. A ZSM hides a message in the rooms of their
-- own zone (or any announcement). The body is replaced by '[removed]'; the
-- audit row holds ids and the reason, never the original body. Direct chats
-- are private and cannot be moderated.

create or replace function public.hide_chat_message(
  p_idempotency_key uuid,
  p_message_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_msg    public.chat_messages;
  v_ch     public.chat_channels;
  v_zone   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'hide_chat_message',
               jsonb_build_object('message', p_message_id, 'reason', v_reason));
  if v_prior is not null then return v_prior; end if;

  if length(v_reason) not between 1 and 200 then
    raise exception 'a reason of 1 to 200 characters is required' using errcode = 'P0001';
  end if;

  select m.* into v_msg from public.chat_messages m
   where m.id = p_message_id and m.tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'message not found' using errcode = 'P0001';
  end if;

  select c.* into v_ch from public.chat_channels c
   where c.id = v_msg.channel_id and c.tenant_id = v_me.tenant_id;

  if v_ch.channel_type = 'DIRECT' then
    raise exception 'direct chats cannot be moderated' using errcode = '42501';
  elsif v_ch.channel_type = 'TERRITORY' then
    select t.zone_id into v_zone from public.territories t
     where t.tenant_id = v_ch.tenant_id and t.id = v_ch.territory_id;
  elsif v_ch.channel_type = 'ZONE' then
    v_zone := v_ch.zone_id;
  end if;
  if v_ch.channel_type in ('TERRITORY', 'ZONE') and v_zone is distinct from v_me.zone_id then
    raise exception 'this room is outside your zone' using errcode = '42501';
  end if;

  if v_msg.hidden_at is null then
    update public.chat_messages
       set body = '[removed]', hidden_at = now(), hidden_by = v_me.profile_id
     where id = v_msg.id
     returning * into v_msg;

    perform public.write_audit(v_me.tenant_id, 'CHAT_MESSAGE_HIDDEN', 'chat_messages', v_msg.id::text,
      null, jsonb_build_object('message_id', v_msg.id, 'channel_id', v_msg.channel_id,
                               'reason', v_reason), p_idempotency_key);
  end if;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('message_id', v_msg.id, 'hidden_at', v_msg.hidden_at));
end;
$$;
revoke all on function public.hide_chat_message(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.hide_chat_message(uuid, uuid, text) to authenticated;
