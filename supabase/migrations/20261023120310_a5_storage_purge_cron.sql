-- Addendum A5 R12 — pg_cron calls the storage-purge Edge Function, which
-- drains storage_purge_queue through the Storage API. Same Vault secrets as
-- the D1 jobs (functions_base_url, cron_secret); cron.schedule upserts by name.
select cron.schedule('storage-purge', '*/15 * * * *',
  $$select public.invoke_system_function('storage-purge', '{}'::jsonb)$$);
