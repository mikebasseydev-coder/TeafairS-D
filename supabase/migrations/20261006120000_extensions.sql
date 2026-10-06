-- Spec A §14 phase 1 — extensions.
-- pgcrypto: bcrypt PINs, HMAC for BVN hashes, OTP hashes.
-- postgis:  zone/territory boundaries, shop and waypoint points, geofences.
-- pg_cron:  scheduled jobs (pickup escalation, rollups, reconciliation sweep).
--
-- Supabase convention: extensions live in the `extensions` schema, so every
-- PostGIS type and function is referenced as extensions.<name>. pg_cron
-- installs into pg_catalog and creates its own `cron` schema.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists postgis  with schema extensions;
create extension if not exists pg_cron  with schema pg_catalog;
