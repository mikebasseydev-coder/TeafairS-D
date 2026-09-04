# Notifications

**Spec:** §5.12, §3.5, §11

## Purpose

Per-user in-app inbox, polled (not realtime), with SMS escalation for the subset
that must reach someone not looking at the app.

## Tables

- `notifications` — the in-app inbox. `recipient_id`, `category`
  (`ACTION_REQUIRED|FYI`), `type` (text — `ORDER_REJECTED`,
  `TRANSFER_AWAITING_VERIFICATION`, `TRANSFER_DISPUTED`, `FINANCING_OFFER`,
  `FUNDING_VERIFIED`, `REPAYMENT_MILESTONE`, `FEE_DUE`, `FEE_PAID`,
  `REVIEW_FLAGGED`, `COUNT_REVIEWED`, `LOW_STOCK`, `CONSIGNMENT_NEAR_LIMIT`,
  `DEPOT_CHECKIN_DUE`, `ENTITY_VERIFIED`, `ALERT`, …), `title`, `body`,
  `deep_link` (jsonb `{screen, record_id}`), `reference_type`/`reference_id`,
  `read_at?`. RLS: `recipient_id = (select auth.uid())`.
- `notifications_outbox` — external fan-out. `notification_id?`, `channel`
  (`sms|push`), `recipient`, `template`, `params`, `status`
  (`PENDING/SENT/FAILED`), `attempts`, `sent_at?`. INSERT-only by RPCs alongside
  the `notifications` row.
- `device_tokens` (push fast-follow) — `profile_id`, `platform` (`android`),
  `token`, `last_seen_at`.

## Delivery

- **In-app: polling.** Each app fetches unread on foreground and every
  ~60–120 s while active. Shell notification centre: unread count,
  `ACTION_REQUIRED` badged separately, tap deep-links to the item.
- **SMS:** `notify` Edge Function drains `notifications_outbox` once per minute
  (`drain_notifications_outbox` job).
- **Push (FCM):** fast-follow — `notify`'s push channel + background delivery for
  `ACTION_REQUIRED` types. In-app + SMS cover launch.
- The single realtime channel (fintech offer inbox) is separate and stays that
  way — notifications are never realtime.

## RPCs

`mark_notifications_read(ids[])` / `mark_all_notifications_read()` — own rows.
`register_device_token(platform, token)` — push fast-follow.
Notification rows are inserted by the RPCs that do the underlying work and by the
alert batch jobs.

## Who gets what (examples)

| Role | Triggers |
|---|---|
| FIELD_AGENT | order confirmed/rejected, payment verified, fintech accepted/declined/funded/repaid/defaulted, outlet/guarantor verified, delivery `NEEDS_REVIEW` |
| WAREHOUSE_MANAGER / INFORMAL_REP | transfer awaiting verification, transfer disputed, order to fulfil, count reviewed, low stock, consignment near limit, check-in due |
| FINTECH_AGENT | new offer (realtime + notification), funding verified, repayment milestone, fee paid, dispute, PIN lockout |
| REGIONAL_MANAGER / COMPLIANCE_OFFICER / ADMIN | review-queue item, fraud alert, SLA breach, funding/payment awaiting verification, fee due |
