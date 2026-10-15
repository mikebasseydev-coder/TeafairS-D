-- Addendum A1 §3.1. Kept apart from the schema migration: a label added with
-- ALTER TYPE … ADD VALUE cannot be used in the transaction that adds it.

-- where a POS terminal physically sits; a different axis from
-- order_channel_enum, which says how a sale was made (A1 decision 5)
create type public.venue_channel_enum as enum (
  'CHURCH', 'MOSQUE', 'HOSPITAL', 'OFFICE_COMPLEX', 'RESIDENTIAL_ESTATE',
  'EDUCATIONAL_INSTITUTION', 'EVENT_CENTER', 'TRANSIT_HUB', 'OPEN_MARKET', 'OTHER'
);

-- rows written through a public gateway: no actor, like WEBHOOK
alter type public.audit_source_enum add value 'WEB';
