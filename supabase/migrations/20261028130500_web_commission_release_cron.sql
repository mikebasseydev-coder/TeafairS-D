-- A6 §15.4: the commission release function is web-commission-release.
select cron.unschedule('fintech-commission-release');
select cron.schedule('web-commission-release', '0 6 * * *',
  $$select public.invoke_system_function('web-commission-release', '{}'::jsonb)$$);
