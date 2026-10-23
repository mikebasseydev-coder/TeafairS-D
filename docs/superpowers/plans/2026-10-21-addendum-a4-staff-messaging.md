# Internal Staff Messaging (Addendum A4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Field staff (ZSM, TM, ASM, DSM, DSA) can chat in four ways:
- private direct chats along the chain;
- a two-way room per territory;
- a ZSM+TM room per zone;
- a tenant announcement stream.

Who can read what is derived live from `tenant_users`.

**Architecture:**
- **Tables.** Three tenant-owned tables: `chat_channels` (direct chats carry a sorted participant pair), `chat_messages` and `chat_read_state`.
- **Read access.** One SECURITY DEFINER helper, `my_chat_channel_ids()`, decides every read. RLS uses it on all three tables, and Realtime filters through that RLS.
- **Writes.** Every write goes through four RPCs on the standard write contract.
- **Group channel rows.** Rows for territories, zones and tenants are backfilled, and created by insert triggers. Membership is never stored.

**Tech Stack:** Postgres 15 (Supabase local), pgTAP, Supabase Realtime publication.

**Spec:** `docs/superpowers/specs/2026-10-21-addendum-a4-staff-messaging-design.md` (Addendum A4). Read §2 and §7 before any task. Spec A §9 and `supabase/CLAUDE.md` ("Writing a migration / an RPC") apply to every task.

## Global Constraints

- **Scope.** Backend only, with no client code. Leave the untracked `FIGMA.md` alone. Branch: `docs/addendum-a4-staff-messaging`, which is cut from the A3 branch head.
- **Remote.** Never push to GitHub. Never run `supabase db push`, `functions deploy` or `config push`. Nothing touches the remote `vwmjyfjdwrohfizljxrq`.
- **Grants and RLS.** `authenticated` gets `SELECT` only on the tables. RLS policies are `FOR SELECT` only, in the form `x in (select public.f())`. Never use a per-row correlated subquery.
- **Function security.**
  - Every `SECURITY DEFINER` function sets `search_path = public, pg_temp`.
  - Every new function first runs `revoke all … from public, anon, authenticated, service_role`, then gets only the grants the spec names.
  - Internal helpers and trigger functions get no grant at all.
- **Write contract.** Each RPC:
  - takes `p_idempotency_key uuid` first;
  - calls `assert_tenant_role(array['ZSM','TM','ASM','DSM','DSA']::public.tenant_role_enum[])`;
  - then `idempotency_begin`, then its writes, then `write_audit` (source `USER`, never the body), then `idempotency_complete`;
  - has no `p_tenant_id` parameter.
- **Schema rules.** Workflow values are `text` + `CHECK`. FKs are `ON DELETE RESTRICT`. Tenant rows reference each other through composite `(tenant_id, x)` FKs. People are `profiles(id)`.
- **What counts as staff.** The staff role set is exactly ZSM, TM, ASM, DSM, DSA.
  - "Available" means ACTIVE and holding a staff role in that tenant (spec §7.6).
  - A non-ZSM's zone always comes from `territories.zone_id`. A ZSM's zone comes from `tenant_users.zone_id`.
- **Privacy.** No message body ever appears in an audit row or a notification payload. A direct chat is readable only by its two participants.
- **Errors.** `P0001` maps to 422 and `42501` to 403. The throttle copy is exactly: `Too many messages. Please wait a moment.`
- **Body.** 1–2000 characters after `btrim`.
- **Files.**
  - Migrations: `supabase/migrations/20261022<hhmmss>_chat_<topic>.sql`.
  - pgTAP: `supabase/tests/database/0NN_chat_<topic>.test.sql`, numbered from 023.
- **Testing.** Run `supabase test db` only after `supabase db reset`. If the first run after a reset sees an empty DB, wait a few seconds and rerun.
- **Commits.** Every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Decisions this plan makes where the spec is silent

1. **Shared rules live in two internal helpers**, so the RPCs and RLS cannot drift apart:
   - `public.chat_staff_zone(p_tenant uuid, p_profile uuid) returns uuid` gives the person's zone under the spec §7.2 rule, or null if they are unavailable.
   - `public.chat_is_available(p_tenant uuid, p_profile uuid) returns boolean`.
2. **Read state lives on the row.** Posting advances the sender's own `chat_read_state` inside `post_chat_message`. There is no separate call.
3. **Notification titles:**
   - DIRECT: `New message`, body `You have a new message.`
   - ANNOUNCEMENT: `Announcement`, body `There is a new announcement.`

   Bodies never quote the message.
4. **Test files are split by task:**
   - 023 `chat_schema` (schema, the access matrix, triggers);
   - 024 `chat_direct`;
   - 025 `chat_post` (post, read, list);
   - 026 `chat_moderation` (hide, plus the grants sweep).

## Review Focus

1. **A ZSM trying to read a direct chat between two of their DSAs.** They must see 0 messages and 0 channels (Task 1 test).
2. **A DSA moved from Ikeja to Epe.** On the next read, the Ikeja room is gone and the Epe room is visible, with no other write needed (Task 1 test).
3. **The same pair opened from both sides with different keys.** It must give one channel, with `created` true then false (Task 2 test).
4. **Posting to a direct chat after the partner becomes a FINTECH_AGENT.** The post is refused with `this person is no longer available`, and the history is still readable (Task 3 test).
5. **Announcement fan-out.** It reaches every available staff member, and no disabled user, fintech agent or shop owner. Its payload keys are exactly `{channel_id, message_id}` (Task 3 test).

---

## File structure

```
supabase/migrations/
  20261022120000_chat_schema.sql      tables, helpers, my_chat_channel_ids, RLS, grants, triggers, backfill, Realtime (T1)
  20261022120100_chat_direct.sql      get_or_create_direct_channel (T2)
  20261022120200_chat_post.sql        post_chat_message, mark_chat_read, list_my_chat_channels (T3)
  20261022120300_chat_moderation.sql  hide_chat_message (T4)
supabase/tests/database/
  023_chat_schema.test.sql (T1)   024_chat_direct.test.sql (T2)
  025_chat_post.test.sql   (T3)   026_chat_moderation.test.sql (T4)
  001_schema_shape.test.sql        42 → 45 tables (T1)
supabase/CLAUDE.md, CLAUDE.md      (T4)
```

pgTAP style:
- Follow `019_support_tickets.test.sql` and `021_support_staff.test.sql`.
- To act as a user, use `set local role authenticated` plus `request.jwt.claims` carrying `sub` and `app_metadata.active_tenant_id`.
- Fixtures that insert into `territories`, `zones` or `tenants` create channel rows through the T1 triggers. Count channels relative to the fixtures you create.

Common fixture shape for all four tests:
- Tenant T1:
  - zone Lagos, with ZSM `Z`;
  - territory Ikeja: TM `TA`, ASM `AA`, DSM `MA`, DSA `DA`, plus a second DSA `DA2`;
  - territory Epe: TM `TB` and DSA `DB`;
  - zone Kano (a second zone): territory Fagge with DSA `DK`;
  - FINTECH_AGENT `F` in Ikeja;
  - DISABLED DSA `X` in Ikeja.
- Tenant T2: a ZSM `Z2`.

---

### Task 1: Chat schema, access helper, RLS, triggers, Realtime

**Files:**
- Create: `supabase/migrations/20261022120000_chat_schema.sql`
- Create: `supabase/tests/database/023_chat_schema.test.sql`
- Modify: `supabase/tests/database/001_schema_shape.test.sql` (add the three tables; 42 → 45)

**Interfaces:**
- **Produces the three tables** exactly as in spec §3.1–§3.3:
  - each type CHECK ties a type to its own columns;
  - partial unique indexes on `(tenant_id, territory_id) where channel_type='TERRITORY'`, `(tenant_id, zone_id) where channel_type='ZONE'`, `(tenant_id) where channel_type='ANNOUNCEMENT'` and `(tenant_id, direct_low_id, direct_high_id) where channel_type='DIRECT'`;
  - `chat_messages (channel_id, created_at, id)` and `(sender_id, created_at)` indexes, plus an index on every FK.
- **Internal helpers** (no grants):
  - `public.chat_is_available(p_tenant uuid, p_profile uuid) returns boolean`. STABLE. True when there is an ACTIVE `tenant_users` row with a staff role.
  - `public.chat_staff_zone(p_tenant uuid, p_profile uuid) returns uuid`. STABLE. For a ZSM it is `tenant_users.zone_id`. For the other staff roles it is `territories.zone_id` through their `territory_id`. It is null if the person is unavailable.
- **`public.my_chat_channel_ids() returns setof uuid`.**
  - SECURITY DEFINER, STABLE, `search_path` pinned. Granted to `authenticated` only.
  - Covers every ACTIVE staff membership of `auth.uid()`, under the rules in spec §3.4 with the §7 clarifications. A ZSM sees every TERRITORY channel whose territory is in their zone.
- **Policies:**
  - `chat_channels` on `id`;
  - `chat_messages` on `channel_id`;
  - `chat_read_state` on `channel_id in (…) and profile_id = (select auth.uid())`.
- **Grants:** `select` on the three tables to `authenticated`.
- **Trigger function** `public.chat_create_group_channel()`. SECURITY DEFINER with no grants. Wire it as:
  - `AFTER INSERT ON territories` (TERRITORY);
  - `AFTER INSERT ON zones` (ZONE);
  - `AFTER INSERT ON tenants` (ANNOUNCEMENT).

  It inserts with `on conflict do nothing`.
- **Backfill** in the same migration: one channel per existing territory, zone and tenant.
- **Realtime:** `alter publication supabase_realtime add table public.chat_messages, public.chat_channels;`

- [ ] **Step 1: Write the failing tests** in `023`, using the common fixtures. Insert the DIRECT channel `D1` (DA–DA2) and a few messages directly as postgres.

  ```sql
  select throws_ok(<TERRITORY channel with zone_id also set>, '23514', null, 'type ties to its columns');
  select throws_ok(<DIRECT with direct_low_id >= direct_high_id>, '23514', null, 'direct pair is sorted');
  select throws_ok(<second TERRITORY channel for Ikeja>, '23505', null, 'one room per territory');
  select throws_ok(<message body '   '>, '23514', null, 'empty body refused');
  select throws_ok(<message whose tenant differs from the channel>, '23503', null, 'composite FK keeps tenants apart');
  select is(<count channels for Ikeja/Epe/Fagge (TERRITORY), Lagos/Kano (ZONE), T1 (ANNOUNCEMENT)>, <1 each>, 'insert triggers create group channels');
  select ok(not has_table_privilege('authenticated', 'public.chat_messages', 'insert'), 'no client writes');
  select ok(not has_table_privilege('anon', 'public.chat_channels', 'select'), 'anon reads nothing');
  -- access matrix (count visible channels by type, as each user)
  select is(<DA sees: TERRITORY Ikeja, ANNOUNCEMENT T1, DIRECT D1; no ZONE>, true, 'DSA: own room, announcements, own DM');
  select is(<MA and AA see TERRITORY Ikeja and ANNOUNCEMENT, no ZONE>, true, 'DSM and ASM: own room only');
  select is(<TA sees TERRITORY Ikeja + ZONE Lagos + ANNOUNCEMENT; not Epe>, true, 'TM: own room and zone room');
  select is(<Z sees TERRITORY Ikeja and Epe, ZONE Lagos, ANNOUNCEMENT; not Fagge, not Kano>, true, 'ZSM: whole zone');
  select is(<count D1 messages visible to Z>, 0, 'ZSM cannot read a direct chat');
  select is(<count D1 messages visible to TA>, 0, 'TM cannot read a direct chat');
  select is(<count channels visible to F>, 0, 'fintech agent sees no chat');
  select is(<count channels visible to X (DISABLED)>, 0, 'disabled user sees nothing');
  select is(<count channels visible to Z2 in T1>, 0, 'other tenant sees nothing');
  -- moved user: update DA territory to Epe as postgres, then as DA:
  select is(<DA sees TERRITORY Epe and not Ikeja>, true, 'moved DSA follows the move at once');
  select is(<DA still sees D1 messages>, <n>, 'direct history survives a move');
  select ok(exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='chat_messages'), 'messages in Realtime');
  select ok(not has_function_privilege('authenticated', 'public.chat_is_available(uuid,uuid)', 'execute'), 'helper is internal');
  ```
- [ ] **Step 2: Run it.** `docker exec -i supabase_db_teafair psql -U postgres -qAt < supabase/tests/database/023_chat_schema.test.sql`. Expected: FAIL, because relation `chat_channels` does not exist.
- [ ] **Step 3: Write the migration.** Then update `001_schema_shape` for the 3 new tables.
- [ ] **Step 4: Run** `supabase migration up`, then `023`, then `supabase db reset && supabase test db`. Expected: all PASS. The baseline before this task is 22 files and 921 tests.
- [ ] **Step 5: Commit.** `feat(db): staff chat schema, live-derived access, RLS, Realtime (A4 §3)`

---

### Task 2: Direct chats

**Files:**
- Create: `supabase/migrations/20261022120100_chat_direct.sql`
- Create: `supabase/tests/database/024_chat_direct.test.sql`

**Interfaces:**
- **Consumes** from Task 1: the tables, `chat_is_available`, `chat_staff_zone` and `my_chat_channel_ids`.
- **Produces** `public.get_or_create_direct_channel(p_idempotency_key uuid, p_target_profile_id uuid) returns jsonb`, which returns `{channel_id, created}`. Granted to `authenticated`.
  - **Target is the caller:** P0001 `you cannot message yourself`.
  - **Target unavailable** in the caller's active tenant: P0001 `that person is not available`.
  - **Scope**, per spec §4.1, symmetric. Any of these allows the chat:
    - both people share a `territory_id`;
    - one is a ZSM and `chat_staff_zone` of the other equals that ZSM's zone;
    - both are TM or ZSM and their `chat_staff_zone` values are equal.

    Anything else raises 42501.
  - The pair is sorted with `least`/`greatest`. Insert with `on conflict … do nothing`, then select the row, so a concurrent or reversed create returns the same channel.
  - Audit `get_or_create_direct_channel` only when a channel is created. The after-image is `{channel_id, other_profile_id}`.

- [ ] **Step 1: Write the failing tests** in `024`.

  ```sql
  select is(<DA opens with DA2> ->> 'created', 'true', 'same territory allowed');
  select is(<DA2 opens with DA, new key> ->> 'channel_id', <same id>, 'reversed pair returns the same channel');
  select is(<that reply> ->> 'created', 'false', 'and does not create');
  select is(<replay DA's key> ->> 'channel_id', <same id>, 'replay returns the stored reply');
  select lives_ok(<DA opens with Z>, 'zone ZSM allowed');
  select lives_ok(<TA opens with TB>, 'two TMs in one zone allowed');
  select lives_ok(<Z opens with DB>, 'ZSM reaches anyone in the zone');
  select throws_ok(<DA opens with DB (Epe)>, '42501', null, 'DSA cannot reach another territory');
  select throws_ok(<DA opens with DK (Kano)>, '42501', null, 'nor another zone');
  select throws_ok(<TA opens with DK>, '42501', null, 'TM cannot reach another zone');
  select throws_ok(<DA opens with F>, 'P0001', 'that person is not available', 'fintech agent unavailable');
  select throws_ok(<DA opens with X>, 'P0001', 'that person is not available', 'disabled user unavailable');
  select throws_ok(<DA opens with DA>, 'P0001', 'you cannot message yourself', 'no self chat');
  select throws_ok(<F calls it>, '42501', null, 'fintech agent cannot open chats');
  select is(<count audit rows get_or_create_direct_channel for the DA–DA2 pair>, 1, 'audited once, on create');
  select ok(not has_function_privilege('anon', 'public.get_or_create_direct_channel(uuid,uuid)', 'execute'), 'not for anon');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL, because the function does not exist.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `024`, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): staff direct chats with chain-scoped access (A4 §4.1)`

---

### Task 3: Posting, read state and the inbox

**Files:**
- Create: `supabase/migrations/20261022120200_chat_post.sql`
- Create: `supabase/tests/database/025_chat_post.test.sql`

**Interfaces:**
- **Consumes:** Task 1 helpers and Task 2's `get_or_create_direct_channel` (used for fixtures).
- **Produces** three functions, all granted to `authenticated`:
  - **`public.post_chat_message(p_idempotency_key uuid, p_channel_id uuid, p_body text) returns jsonb`**, returning `{message_id, created_at}`.
    - The channel must be visible: it must be in `my_chat_channel_ids()` and have `tenant_id` equal to the active tenant. Otherwise 42501.
    - ANNOUNCEMENT needs the caller to be a ZSM, else 42501.
    - DIRECT needs both participants available, else P0001 `this person is no longer available`.
    - The body is trimmed and must be 1–2000 characters, else P0001.
    - Throttle: if the sender already has 20 or more messages in this tenant in the last minute, raise P0001 with the throttle copy.
    - It then:
      - writes the message;
      - sets `chat_channels.last_message_at`;
      - upserts the sender's `chat_read_state` to the message's `created_at`;
      - writes notifications per plan Decision 3: DIRECT goes to the other participant; ANNOUNCEMENT goes to every available staff member except the sender, in one `insert … select`.
    - Audit `post_chat_message`, with the after-image `{message_id, channel_id, channel_type}`.
  - **`public.mark_chat_read(p_idempotency_key uuid, p_channel_id uuid, p_read_up_to timestamptz) returns jsonb`**, returning `{channel_id, last_read_at}`.
    - The channel must be visible, else 42501.
    - Upsert `last_read_at = greatest(existing, least(p_read_up_to, now()))`.
    - It writes no audit row (spec §4.3).
  - **`public.list_my_chat_channels() returns setof jsonb`**. STABLE, SECURITY DEFINER, `search_path` pinned.
    - One object per channel in `my_chat_channel_ids()`: `{channel_id, tenant_id, channel_type, territory_id, zone_id, other_profile_id, last_message_at, unread_count}`.
    - `unread_count` counts messages newer than the caller's `last_read_at` that were not sent by the caller, capped at 100 (spec §7.8).
    - Ordered by `last_message_at desc nulls last`, then `channel_id`.

- [ ] **Step 1: Write the failing tests** in `025`.

  ```sql
  select is(<DA posts to TERRITORY Ikeja> ? 'message_id', true, 'DSA posts in the team room');
  select throws_ok(<DA posts to TERRITORY Epe>, '42501', null, 'not another territory');
  select throws_ok(<DA posts to ZONE Lagos>, '42501', null, 'DSA not in the zone room');
  select lives_ok(<TA posts to ZONE Lagos>, 'TM posts in the zone room');
  select throws_ok(<TA posts to ANNOUNCEMENT>, '42501', null, 'only ZSMs announce');
  select lives_ok(<Z posts to ANNOUNCEMENT>, 'ZSM announces');
  select is(<recipients of that CHAT_ANNOUNCEMENT>, <every available T1 staff except Z; not F, not X>, 'announcement reaches staff only');
  select ok(<every CHAT_ANNOUNCEMENT payload has keys exactly {channel_id, message_id}>, 'no body in payload');
  select is(<count notifications from a TERRITORY post>, 0, 'rooms do not notify');
  select is(<DA posts in D1: count CHAT_MESSAGE for DA2>, 1, 'direct message notifies the other person');
  -- partner unavailable: set DA2 role to FINTECH_AGENT as postgres
  select throws_ok(<DA posts in D1>, 'P0001', 'this person is no longer available', 'cannot post to an unavailable partner');
  select is(<count D1 messages visible to DA>, <n>, 'history still readable');
  select throws_ok(<21st post by one sender within a minute>, 'P0001', 'Too many messages. Please wait a moment.', 'throttle');
  select throws_ok(<body repeat('x', 2001)>, 'P0001', null, 'over 2000 refused');
  select ok(<no audit row from these RPCs contains any posted body>, 'no bodies in audit');
  -- read state and inbox
  select is(<list_my_chat_channels() as DA2 for TERRITORY Ikeja: unread_count>, <posts by others>, 'unread counts others only');
  select is(<after mark_chat_read(now()) as DA2: unread_count>, 0, 'mark read clears');
  select is(<mark_chat_read with an earlier timestamp keeps the later one>, true, 'read state moves forward only');
  select is(<unread_count after 105 posts by others>, 100, 'unread is capped at 100');
  select is(<first row of list_my_chat_channels() as DA> ->> 'channel_id', <most recently active channel>, 'inbox ordered by activity');
  select is(<sender's own unread_count after posting>, 0, 'own posts are read');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `025`, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): staff chat posting, read state, inbox (A4 §4.2–4.5)`

---

### Task 4: Moderation, grants sweep, docs

**Files:**
- Create: `supabase/migrations/20261022120300_chat_moderation.sql`
- Create: `supabase/tests/database/026_chat_moderation.test.sql`
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md`

**Interfaces:**
- **Produces** `public.hide_chat_message(p_idempotency_key uuid, p_message_id uuid, p_reason text) returns jsonb`, returning `{message_id, hidden_at}`. Granted to `authenticated`.
  - Only a ZSM may call it.
  - The message must be in the active tenant, else P0001 `message not found`.
  - A message in a DIRECT channel raises 42501.
  - TERRITORY or ZONE channels must be in the ZSM's zone, else 42501. ANNOUNCEMENT is allowed for any ZSM of the tenant.
  - `p_reason` must be 1–200 characters after trimming, else P0001.
  - The update sets `body = '[removed]'`, `hidden_at = now()` and `hidden_by = me`.
  - Hiding an already-hidden message returns the current row and writes no new audit row.
  - Audit `CHAT_MESSAGE_HIDDEN`, with the after-image `{message_id, channel_id, reason}`.

- [ ] **Step 1: Write the failing tests** in `026`.

  ```sql
  select is(<Z hides a DA post in TERRITORY Ikeja> ? 'hidden_at', true, 'ZSM hides a room message');
  select is(<that message body>, '[removed]', 'body removed');
  select ok(<CHAT_MESSAGE_HIDDEN after-image keys = {message_id, channel_id, reason} and no original body anywhere in audit>, 'audit has no body');
  select throws_ok(<TA hides a message>, '42501', null, 'TM cannot moderate');
  select throws_ok(<Z hides a message in D1>, '42501', null, 'direct chats cannot be moderated');
  select throws_ok(<Z hides a message in Fagge (Kano)>, '42501', null, 'only in own zone');
  select lives_ok(<Z hides an ANNOUNCEMENT message>, 'any ZSM moderates announcements');
  select is(<hide again with a new key: count CHAT_MESSAGE_HIDDEN for it>, 1, 'repeat hide writes no second audit');
  select throws_ok(<reason '  '>, 'P0001', null, 'reason required');
  -- grants across A4: one ok() per (anon, service_role) × every A4 function, guarded with to_regprocedure,
  --   and `not has_function_privilege('authenticated', …)` for chat_is_available, chat_staff_zone, chat_create_group_channel
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `026`, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Update the docs.**
  - In `supabase/CLAUDE.md`:
    - add the status row `A4. Internal staff messaging — chat channels, direct chats, team/zone rooms, announcements | done (local)`;
    - list the four RPCs and `list_my_chat_channels`;
    - describe the live-derived access rule and that direct chats are private;
    - note that the Realtime publication includes `chat_messages` and `chat_channels`;
    - note that A4 has no Edge Functions or secrets.
  - In the root `CLAUDE.md`: update the repository-state counts from real commands, and add the A4 spec row after A3.
- [ ] **Step 6: Commit.** `feat(db): staff chat moderation, grants sweep; docs: A4 status (A4 §4.4)`
