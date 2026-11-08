-- Addendum A8 §7.2, §7.4 (plan Task 7): the monvelo-insurance-declare cron
-- job, and the MANUAL outcome its adapter reports.
--
-- complete_monvelo_declaration is recreated from 20261031122200 (signature and
-- grant unchanged). MANUAL puts a claimed row back to PENDING with
-- next_attempt_at = 'infinity': it is never claimed again and waits for an
-- operator's record_monvelo_declaration_outcome. Every other outcome goes to
-- monvelo_apply_declaration_outcome as before.
create or replace function public.complete_monvelo_declaration(p_id uuid, p_outcome text, p_insurer_reference text,
                                                               p_error text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
begin
  if p_outcome = 'MANUAL' then
    update public.monvelo_insurance_declarations
       set status = 'PENDING', next_attempt_at = 'infinity'
     where id = p_id and status = 'SENDING'
    returning status into v_status;
    if v_status is null then
      return jsonb_build_object('declaration_id', p_id, 'ignored', true);
    end if;
    return jsonb_build_object('declaration_id', p_id, 'status', 'PENDING', 'manual', true);
  end if;
  return public.monvelo_apply_declaration_outcome(p_id, p_outcome, p_insurer_reference, p_error, null);
end;
$$;
revoke all on function public.complete_monvelo_declaration(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.complete_monvelo_declaration(uuid, text, text, text) to service_role;

-- every minute, as email-outbox-send; needs the functions_base_url and
-- cron_secret Vault secrets (cron.schedule upserts by name)
select cron.schedule('monvelo-insurance-declare', '* * * * *',
  $$select public.invoke_system_function('monvelo-insurance-declare', '{}'::jsonb)$$);
