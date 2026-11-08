-- Addendum A8 §7.3 (plan Task 8): the insurers' webhook, in the database.
--
--   get_monvelo_insurer_provider(code)        service_role: the adapter to verify with (null: unknown or suspended)
--   record_monvelo_insurer_event(code, id, payload)
--                                              service_role: true if new, false for a repeat (insurer, event_id)
--   apply_monvelo_insurer_event(code, id, type, event)
--                                              service_role: records the event and applies it in one transaction
--
-- An event is applied only to what belongs to the insurer that sent it: its
-- own declaration, its own claim. A target that cannot be found refuses the
-- whole event (P0001), so nothing is recorded and the insurer's retry is
-- applied when it succeeds. Out-of-order claim events are ignored, not
-- refused: settled before under review is fine (FILED -> SETTLED), and a
-- late under-review on a settled claim changes nothing.
-- An unknown or suspended insurer is P0001 (not the plan's P0002, which is
-- PL/pgSQL's no_data_found; supabase/CLAUDE.md).

create or replace function public.get_monvelo_insurer_provider(p_code text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select i.api_provider from public.monvelo_insurers i where i.code = p_code and i.status = 'ACTIVE';
$$;
revoke all on function public.get_monvelo_insurer_provider(text) from public, anon, authenticated;
grant execute on function public.get_monvelo_insurer_provider(text) to service_role;

create or replace function public.monvelo_active_insurer(p_code text)
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  select i.id into v_id from public.monvelo_insurers i where i.code = p_code and i.status = 'ACTIVE';
  if v_id is null then
    raise exception 'unknown insurer' using errcode = 'P0001';
  end if;
  return v_id;
end;
$$;
revoke all on function public.monvelo_active_insurer(text) from public, anon, authenticated, service_role;

create or replace function public.record_monvelo_insurer_event(p_insurer_code text, p_event_id text, p_payload jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_insurer uuid := public.monvelo_active_insurer(p_insurer_code);
  v_new     boolean;
begin
  if p_event_id is null or length(p_event_id) not between 1 and 200 then
    raise exception 'an event id is 1 to 200 characters' using errcode = 'P0001';
  end if;
  insert into public.monvelo_insurer_events (insurer_id, event_id, payload)
  values (v_insurer, p_event_id, coalesce(p_payload, '{}'::jsonb))
  on conflict (insurer_id, event_id) do nothing
  returning true into v_new;
  return coalesce(v_new, false);
end;
$$;
revoke all on function public.record_monvelo_insurer_event(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_monvelo_insurer_event(text, text, jsonb) to service_role;

create or replace function public.apply_monvelo_insurer_event(p_insurer_code text, p_event_id text, p_type text,
                                                              p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_insurer uuid := public.monvelo_active_insurer(p_insurer_code);
  v_event   jsonb := coalesce(p_event, '{}'::jsonb);
  v_ref     text := nullif(btrim(coalesce(v_event ->> 'insurer_reference', '')), '');
  v_decl    uuid;
  v_claim   public.monvelo_insurance_claims;
  v_to      text;
  v_result  jsonb;
begin
  if not public.record_monvelo_insurer_event(p_insurer_code, p_event_id,
                                             jsonb_build_object('type', p_type) || v_event) then
    return jsonb_build_object('duplicate', true);
  end if;

  if p_type in ('declaration.accepted', 'declaration.rejected') then
    select d.id into v_decl from public.monvelo_insurance_declarations d
     where d.id = (v_event ->> 'declaration_id')::uuid and d.insurer_id = v_insurer;
    if v_decl is null then
      raise exception 'declaration not found' using errcode = 'P0001';
    end if;
    v_result := public.monvelo_apply_declaration_outcome(v_decl,
      case p_type when 'declaration.accepted' then 'ACCEPTED' else 'REJECTED' end, v_ref, v_event ->> 'error', null);

  elsif p_type in ('claim.under_review', 'claim.rejected', 'claim.settled') then
    select c.* into v_claim from public.monvelo_insurance_claims c
     where c.reference = v_event ->> 'claim_reference' and c.insurer_id = v_insurer;
    if v_claim.id is null then
      raise exception 'claim not found' using errcode = 'P0001';
    end if;
    if p_type = 'claim.settled' then
      v_result := public.monvelo_settle_claim(v_claim.id, (v_event ->> 'settled_amount')::numeric,
                                              v_event ->> 'payout_reference', null);
    else
      v_to := case p_type when 'claim.under_review' then 'UNDER_REVIEW' else 'REJECTED' end;
      select * into v_claim from public.monvelo_insurance_claims where id = v_claim.id for update;
      if (v_claim.status = 'FILED' and v_to in ('UNDER_REVIEW', 'REJECTED'))
         or (v_claim.status = 'UNDER_REVIEW' and v_to = 'REJECTED') then
        update public.monvelo_insurance_claims
           set status = v_to, insurer_claim_reference = coalesce(v_ref, insurer_claim_reference),
               closed_reason = case when v_to = 'REJECTED' then coalesce(v_event ->> 'error', 'rejected by the insurer')
                                    else closed_reason end
         where id = v_claim.id returning * into v_claim;
        perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'apply_monvelo_insurer_event',
                                   'monvelo_insurance_claims', v_claim.id::text, null,
                                   jsonb_build_object('status', v_to, 'event_id', p_event_id,
                                                      'insurer_claim_reference', v_claim.insurer_claim_reference),
                                   null, 'WEBHOOK');
        perform public.monvelo_notify_claim(v_claim);
        v_result := jsonb_build_object('claim_id', v_claim.id, 'status', v_to);
      else
        v_result := jsonb_build_object('claim_id', v_claim.id, 'ignored', true, 'status', v_claim.status);
      end if;
    end if;

  else
    v_result := jsonb_build_object('ignored', true);
  end if;

  return jsonb_build_object('event_id', p_event_id) || v_result;
end;
$$;
revoke all on function public.apply_monvelo_insurer_event(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.apply_monvelo_insurer_event(text, text, text, jsonb) to service_role;
