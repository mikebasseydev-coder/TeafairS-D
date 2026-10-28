-- A6 §15.6: the unused fintech_advances table is dropped; Monvelo financing
-- replaces it. Its policy, indexes, constraints and updated_at trigger go with
-- the table. pos_network_enum stays: web_pos_partners and monvelo_agents use it.
drop table public.fintech_advances;
