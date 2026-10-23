# Addendum A4 to Spec A — Internal staff messaging

**Status:** written spec approved 2026-10-21; plan `docs/superpowers/plans/2026-10-21-addendum-a4-staff-messaging.md`.
**Authority:** this amends Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`). Spec A §9 applies in full.
**Builds on:** A3 (web chat & ticketing). A4 is branched from A3's branch head so the shared table-count tests line up. A4 does not depend on any A3 table.
**Scope:** backend only, meaning migrations, RPCs and pgTAP. Client UI stays on hold (Spec B).

## 1. Intent

Field staff need to reach each other inside the app instead of over WhatsApp. That means:
- private one-to-one chats along the chain;
- a team room per territory for ground updates;
- a management room per zone;
- a company announcement stream.

Two things have to hold. Chat must never leak across tenants, territories or roles. And who can read a conversation must follow the same live `tenant_users` truth as everything else in the app: claims propose, the database decides.

**Goals**
- Four conversation kinds (§3), with access derived live from `tenant_users`.
- Realtime delivery to authenticated staff, filtered by RLS.
- Unread counts per person per channel.

**Non-goals for v1**
- Attachments, voice and images.
- Editing.
- Reactions, threads and typing indicators.
- Push delivery. That belongs to Spec B. A4 writes `notifications` rows that Spec B can push.
- Retention and expiry.
- Chat with fintech agents, shop owners or buyers. Buyers already have A3.

**Anti-goals.** Each of these would make A4 a failure even if it worked:
- A disabled or moved user who keeps reading a group channel.
- A ZSM, or anyone else, who can read someone else's direct chat.
- Message bodies in audit rows or notification payloads.
- A copied membership list that drifts from `tenant_users`.

## 2. Decisions locked by the user (2026-10-21)

1. **Who chats.** Only ACTIVE `tenant_users` with role ZSM, TM, ASM, DSM or DSA. FINTECH_AGENT and RETAIL_SHOP_OWNER are excluded. Access is lost the moment a row stops being ACTIVE, or its territory or zone changes.
2. **Four kinds.**
   - DIRECT (1:1).
   - TERRITORY: a **two-way** team room. Everyone in it may post.
   - ZONE: the zone's ZSM and its TMs only.
   - ANNOUNCEMENT: one per tenant. Every staff member reads it, and only ZSMs post. There is no HQ or admin role above ZSM (Spec A decision 9).
3. **Direct chats are private to the two people.** No ZSM, TM or anyone else can read them.
4. **Direct-chat scope.** You can open a direct chat with:
   - anyone in your own territory;
   - your zone's ZSM;
   - and, if you are a TM or ZSM, anyone in your zone.

   A DSA in one zone cannot open a chat with a stranger in another.
5. **Group membership is derived live** from `tenant_users`. It is never copied into a members table, and there is no membership sync trigger. A direct chat stores its two participants on the channel row itself, as a sorted pair. That takes the place of `chat_channel_members`.

## 3. Data model

All tables are tenant-owned. FKs are `ON DELETE RESTRICT`; this replaces the brief's `cascade`, per Spec A §9. Tenant rows reference each other through composite `(tenant_id, x)` FKs. People are `profiles(id)`. Statuses are `text + CHECK`.

### 3.1 `chat_channels`

| column | notes |
|---|---|
| `id uuid pk`, `tenant_id uuid not null` | `unique (tenant_id, id)` |
| `channel_type text not null` | `DIRECT \| TERRITORY \| ZONE \| ANNOUNCEMENT` |
| `territory_id uuid` | set only for TERRITORY; FK `(tenant_id, territory_id)` → territories |
| `zone_id uuid` | set only for ZONE; FK `(tenant_id, zone_id)` → zones |
| `direct_low_id uuid`, `direct_high_id uuid` | set only for DIRECT; → profiles; CHECK `direct_low_id < direct_high_id` |
| `last_message_at timestamptz` | null until the first message |
| `created_at timestamptz not null default now()` | |

- CHECKs tie each type to exactly its own columns.
- Partial unique indexes give one channel per territory, one per zone, one ANNOUNCEMENT per tenant, and one DIRECT per `(tenant_id, direct_low_id, direct_high_id)`.
- Group channels need no per-person data, so their rows exist up front:
  - the migration backfills one row per existing territory, zone and tenant;
  - `AFTER INSERT` triggers on `territories`, `zones` and `tenants` create the row for anything new.

  These triggers maintain channels, not membership.

### 3.2 `chat_messages`

| column | notes |
|---|---|
| `id`, `tenant_id`, `channel_id` | FK `(tenant_id, channel_id)` → `chat_channels` |
| `sender_id uuid not null` | → profiles |
| `body text not null` | CHECK `length(btrim(body, E' \t\r\n')) between 1 and 2000`; stored trimmed of the same set |
| `hidden_at timestamptz`, `hidden_by uuid` | moderation (§5); `hidden_by` → profiles |
| `created_at timestamptz not null default clock_timestamp()` | |

- Indexes: `(channel_id, created_at, id)` for the thread, and `(sender_id, created_at)` for the throttle.
- The brief's `metadata jsonb` is dropped. v1 is text only, and a free-form JSON column invites personal data and unvalidated client input. *(Builder's call.)*

### 3.3 `chat_read_state`

`(tenant_id, channel_id, profile_id)` is the primary key, plus `last_read_at timestamptz not null`. Rows are written by `mark_chat_read`, and posting advances the sender's own row (§4.2). Unread count = messages in the channel with `created_at > last_read_at` (all messages if there is no row), excluding the caller's own messages.

### 3.4 Access: the single source of truth

`public.my_chat_channel_ids() returns setof uuid` is SECURITY DEFINER, STABLE, with `search_path` pinned, and granted to `authenticated` only. For each of the caller's ACTIVE `tenant_users` rows whose role is in the staff set, it returns:
- **TERRITORY:** the caller's own `territory_id` channel, for TM, ASM, DSM and DSA. For a ZSM, every territory channel in the ZSM's zone.
- **ZONE:** a ZSM's own `zone_id` channel. For a TM, the zone of the TM's territory.
- **ANNOUNCEMENT:** the tenant's channel, for every staff role.
- **DIRECT:** channels where `direct_low_id` or `direct_high_id` is the caller, in that tenant, and only while the caller is ACTIVE. The other participant's status does not hide the history.

**Policies.** All are FOR SELECT, `x in (select public.my_chat_channel_ids())`:
- `chat_channels` on `id`;
- `chat_messages` on `channel_id`;
- `chat_read_state` additionally requires `profile_id = (select auth.uid())`.

**Grants.** `authenticated` gets SELECT on all three tables; nothing is granted to `anon`.

**Realtime.** `alter publication supabase_realtime add table public.chat_messages, public.chat_channels;` so `last_message_at` can re-order inbox lists.

## 4. RPCs (write contract)

Every RPC:
- takes `p_idempotency_key uuid` first;
- calls `assert_tenant_role(staff roles)`, so the tenant comes from the JWT and is re-verified live;
- runs `idempotency_begin`, then the writes, then `idempotency_complete`; write_audit for moderation only (user decision 2026-10-22), source `USER`, never the body (§7.9);
- is SECURITY DEFINER with `search_path` pinned, revoked from public, anon and service_role, and granted to `authenticated`.

Errors: P0001 → 422, 42501 → 403.

1. **`get_or_create_direct_channel(p_idempotency_key uuid, p_target_profile_id uuid) returns jsonb`** → `{channel_id, created}`.
   - Refused if the target is the caller (P0001).
   - Refused unless the target is an ACTIVE staff member of the caller's tenant (P0001 `that person is not available`).
   - Refused unless decision 4 allows the pair (42501).
   - The scope rule is symmetric:
     - **same territory:** the two people share a `territory_id`;
     - **zone ZSM:** one is the ZSM of the other's zone;
     - **zone management:** both are a TM or ZSM in the same zone.
   - Returns the existing channel for a sorted pair; concurrent creates resolve through the unique index.
   - The scope is checked only when the chat is created. The existing sorted pair is looked up after the self and availability checks and before the scope rule, so an existing direct chat is returned (`created: false`) and stays usable while both people are ACTIVE in the tenant, even if one moves. *(Builder's call: history matters more than re-checking scope on every message.)*
   - Writes no audit row, on create or reopen (§7.9).
2. **`post_chat_message(p_idempotency_key uuid, p_channel_id uuid, p_body text) returns jsonb`** → `{message_id, created_at}`.
   - The channel must be in `my_chat_channel_ids()` for the active tenant, else 42501.
   - Only ZSMs post to ANNOUNCEMENT.
   - DIRECT needs both participants ACTIVE, else P0001 `this person is no longer available`.
   - The body is trimmed of spaces, tabs, CR and LF, then must be 1 to 2000 characters (P0001); it is stored trimmed.
   - Throttle: more than 20 messages from the sender in the last minute raises P0001 `Too many messages. Please wait a moment.` The count is unlocked by design, so parallel posts across channels can slightly exceed 20.
   - The channel row is locked `FOR NO KEY UPDATE`, which does not conflict with the KEY SHARE that FK checks take.
   - Writes the message, bumps `last_message_at`, and advances the sender's own read state. Writes no audit row (§7.9): the message row is the record.
   - Notifications, kind `CHAT_MESSAGE` for DIRECT and `CHAT_ANNOUNCEMENT` for ANNOUNCEMENT. The payload is `{channel_id, message_id}` only and never carries the body.
     - DIRECT → the other participant.
     - ANNOUNCEMENT → every ACTIVE staff member of the tenant, in one set-based insert.
     - TERRITORY and ZONE write no notification rows; they rely on unread counts. Rooms are busy, and a row per member per message would swamp `notifications`.
3. **`mark_chat_read(p_idempotency_key uuid, p_channel_id uuid, p_read_up_to timestamptz) returns jsonb`**. Upserts read state forward only, with `greatest(existing, p_read_up_to)`, and caps it at `clock_timestamp()`, which is consistent with `chat_messages.created_at`. A null `p_read_up_to` raises P0001 `read_up_to is required`. Writes no audit row (§7.9).
4. **`hide_chat_message(p_idempotency_key uuid, p_message_id uuid, p_reason text) returns jsonb`**.
   - Moderation for TERRITORY, ZONE and ANNOUNCEMENT only.
   - Allowed for a ZSM whose zone covers the channel, or any ZSM for ANNOUNCEMENT.
   - Sets `body = '[removed]'`, `hidden_at` and `hidden_by`.
   - Audits `CHAT_MESSAGE_HIDDEN` with `{message_id, channel_id, reason}`, never the original body.
   - DIRECT messages can never be hidden by a third party, because no one but the two people can read them.
5. **`list_my_chat_channels() returns setof jsonb`**. STABLE and read-only: one row per accessible channel with `{channel_id, channel_type, territory_id, zone_id, other_profile_id (DIRECT), last_message_at, unread_count}`, ordered by `last_message_at desc nulls last`. Granted to `authenticated`.

No edits and no self-deletes in v1.

## 5. Behaviour the user will notice

- **A DSA moves from Ikeja to Epe.** Ikeja's room disappears and Epe's appears on their next read. Their direct chats stay.
- **A DSA is disabled.** Everything is gone for them. Their direct-chat partners still see the history but cannot post to them.
- **A ZSM sees every territory room in the zone.** They can post in it and moderate it. They see none of the direct chats.
- **A TM sees and posts in their own territory room and the zone room,** but not in other territories' rooms.

## 6. Tests (pgTAP 023 onward)

Schema and RLS:
- one channel per territory, zone and tenant;
- the DIRECT pair CHECKs;
- composite FKs;
- no client writes.

Access matrix, one assertion per cell:
- the five roles × the four kinds;
- the disabled and moved cases;
- cross-tenant;
- a ZSM cannot read a DIRECT chat.

`get_or_create_direct_channel`:
- each scope rule allowed and refused;
- a replay returns the same channel;
- the reversed pair returns the same channel.

`post_chat_message`:
- permissions;
- only ZSMs post announcements;
- the throttle;
- the notification fan-out and payload keys;
- no audit row (§7.9).

Also:
- `mark_chat_read` moves forward only;
- unread counts;
- `hide_chat_message` scope;
- `[removed]`;
- grants for every function.

## 7. Clarifications

These were settled after the builder check. Each is marked as the builder's call or as an answer.

1. **Tenant scope (builder's call).** Reads follow the app's existing pattern: they span **all** of the caller's ACTIVE memberships, the same as `my_tenant_ids()`. Writes use the JWT's active tenant through `assert_tenant_role`. This leaks nothing across tenants, because a person only ever sees the tenants they belong to. `list_my_chat_channels` returns `tenant_id` on each row, so the client can filter by the active tenant.
2. **Deriving zones (answer).** A non-ZSM's zone always comes from `territories.zone_id`, joined through their `territory_id`. It never comes from `tenant_users.zone_id`. A ZSM's zone is `tenant_users.zone_id`.
3. **Several ZSMs in one zone (builder's call).** "The zone's ZSM" means any ACTIVE ZSM whose `tenant_users.zone_id` is that zone. All of them count for the zone room, the direct-chat scope and moderation.
4. **No archived territory state exists (answer).** New territories and zones appear automatically: the trigger creates their channel, and access is derived live.
5. **Channel triggers (answer).** They are SECURITY DEFINER with `search_path` pinned and revoked from every API role. The backfill covers TEAFAIR and any other existing tenant. A4 adds exactly three tables, so `001_schema_shape` grows by 3.
6. **Who counts as available (builder's call).** A person is available to chat in a tenant when they are ACTIVE **and** hold a staff role there. Someone moved to FINTECH_AGENT or RETAIL_SHOP_OWNER becomes unavailable, exactly like a disabled user.
7. **Throttle (builder's call).** The limit is per sender, per tenant, across all channels.
8. **Unread count (builder's call).** It is capped. `unread_count` counts at most 100 messages per channel, so the client shows "99+" at 100. This keeps a ZSM with many territory rooms cheap to serve.
9. **Chat audit (answer).** Posting, opening a direct chat and marking read write no audit row; only moderation is audited. Reason: audit_logs is readable tenant-wide by TMs and ZSMs, and audit rows would reveal who messages whom (user decision 2026-10-22).

## 8. Left to the builder

- Index details beyond those named.
- Fixture shapes.
- Whether the channel triggers are one function or three.
- The exact `list_my_chat_channels` SQL.

Keep `001_schema_shape` and `003_rls` green.
