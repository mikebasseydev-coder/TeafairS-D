-- Addendum A8 §6.3 (plan Task 9): who may upload a cover document. The
-- monvelo-cover-upload gateway asks this on the caller's own JWT before it
-- signs an upload URL.
--
--   SHOP_POLICY     subject = the shop: an ACTIVE ZSA or ASA covering an area
--                   where the shop is ACTIVE-ly enrolled in the caller's tenant
--                   (the submitters of submit_monvelo_shop_policy)
--   CLAIM_EVIDENCE  subject = the financing: whoever report_monvelo_loss lets
--                   report on it: an operator; in the financing's tenant, a ZSA
--                   or ASA covering its area (STORAGE) or the LM or CSM (GIT)
--
-- It reads only; it never says why not. Anything else is false.
create or replace function public.can_upload_monvelo_cover(p_purpose text, p_subject_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me  public.tenant_users;
  v_fin public.monvelo_financings;
begin
  if (select auth.uid()) is null or p_subject_id is null then
    return false;
  end if;
  if p_purpose = 'CLAIM_EVIDENCE' and public.is_monvelo_operator() then
    return exists (select 1 from public.monvelo_financings f where f.id = p_subject_id);
  end if;
  begin
    v_me := public.assert_tenant_role(array['ZSA', 'ASA', 'LOGISTICS_MANAGER', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  exception when insufficient_privilege then
    return false;
  end;

  if p_purpose = 'SHOP_POLICY' then
    return v_me.role in ('ZSA', 'ASA')
       and exists (select 1 from public.monvelo_shop_enrolments e
                    where e.shop_id = p_subject_id and e.tenant_id = v_me.tenant_id and e.status = 'ACTIVE'
                      and public.monvelo_covers_area(v_me, e.area_id));
  elsif p_purpose = 'CLAIM_EVIDENCE' then
    select * into v_fin from public.monvelo_financings f where f.id = p_subject_id and f.tenant_id = v_me.tenant_id;
    if v_fin.id is null then
      return false;
    end if;
    return (v_me.role in ('ZSA', 'ASA') and public.monvelo_covers_area(v_me, v_fin.area_id))
        or v_me.role in ('LOGISTICS_MANAGER', 'CLIENT_SERVICE_MANAGER');
  end if;
  return false;
end;
$$;
revoke all on function public.can_upload_monvelo_cover(text, uuid) from public, anon, service_role;
grant execute on function public.can_upload_monvelo_cover(text, uuid) to authenticated;
