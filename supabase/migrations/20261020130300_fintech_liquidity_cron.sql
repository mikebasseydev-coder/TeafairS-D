-- Spec D1 §10 — pg_net cron jobs. The database calls the reconcile-funds
-- Edge Function (sweep and refunds) and the commission release on a schedule.
-- The base URL and the shared cron secret live in Vault (functions_base_url,
-- cron_secret); they are created out of band, never in a migration.

create extension if not exists pg_net;

create or replace function public.invoke_system_function(p_function text, p_body jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_base   text;
  v_secret text;
begin
  select decrypted_secret into v_base
    from vault.decrypted_secrets where name = 'functions_base_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'cron_secret';

  if v_base is null or v_secret is null then
    raise log 'invoke_system_function(%): functions_base_url or cron_secret is missing from Vault', p_function;
    return null;
  end if;

  return net.http_post(
    url     := rtrim(v_base, '/') || '/' || p_function,
    body    := coalesce(p_body, '{}'::jsonb),
    headers := jsonb_build_object('content-type', 'application/json',
                                  'x-cron-secret', v_secret),
    -- pg_net's default is 5 s; a sweep of 50 Verify calls takes longer
    timeout_milliseconds := 120000);
end;
$$;

revoke all on function public.invoke_system_function(text, jsonb)
  from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('reconcile-funds-sweep', '*/5 * * * *',
  $$select public.invoke_system_function('reconcile-funds', '{"mode":"sweep"}'::jsonb)$$);
select cron.schedule('reconcile-funds-refunds', '0 5 * * *',
  $$select public.invoke_system_function('reconcile-funds', '{"mode":"refunds"}'::jsonb)$$);
select cron.schedule('fintech-commission-release', '0 6 * * *',
  $$select public.invoke_system_function('fintech-commission-release', '{}'::jsonb)$$);
