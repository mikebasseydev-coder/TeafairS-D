// The RPCs the app may call directly through supabase.rpc (Spec B §6.2,
// Surface "App"). `rpc()` accepts only these names. Gateway-only RPCs, the
// TeafairWeb-only admin RPCs and the RLS helpers are absent on purpose;
// rpc-map.test.ts holds this list against §6 and the generated types.

export const APP_RPCS = [
  // auth / tenant (B2–B3)
  "list_my_invitations",
  "accept_tenant_invitation",
  "decline_tenant_invitation",
  "set_active_tenant",
  "get_my_pin_status",
  "set_tenant_pin",
  "change_tenant_pin",
  "verify_pin",
  // notifications
  "register_device",
  // web referral (POS)
  "upsert_web_referral_code",
  "set_web_pos_venue",
  "pos_order_lookup",
  // field (Spec C)
  "place_trade_order",
  // support (A3/A5)
  "claim_ticket",
  "reply_ticket",
  "update_ticket_status",
  "set_ticket_priority",
  "assign_ticket",
  "redact_ticket_customer_data",
  // chat (A4)
  "list_my_chat_channels",
  "get_or_create_direct_channel",
  "post_chat_message",
  "mark_chat_read",
  "hide_chat_message",
  // monvelo, field activation (ZSA, ASA)
  "get_monvelo_field_dashboard",
  "monvelo_field_partners_near",
  "pair_monvelo_shop_agent",
  "unpair_monvelo_shop_agent",
  "nominate_monvelo_agent",
  "close_monvelo_nomination",
  "request_monvelo_financing",
  "cancel_monvelo_financing",
  "list_monvelo_claim_holds",
  "get_monvelo_claim_hold",
  "decide_monvelo_claim_hold",
  "get_lender_reconciliation_summary",
  "report_monvelo_loss",
  // monvelo, TM
  "get_monvelo_tm_oversight",
  "set_monvelo_supply_day",
  "approve_monvelo_financing",
  // monvelo, agent members
  "pledge_monvelo_funds",
  "monvelo_supply_days_near",
  "monvelo_open_offers",
  "get_monvelo_offer_cover",
  "claim_monvelo_financing",
  "get_monvelo_agent_exposure",
  "accept_monvelo_agent_terms",
  // monvelo, shop owner
  "withdraw_monvelo_shop_consent",
  "reject_monvelo_repayment",
  // monvelo, fulfilment
  "dispatch_monvelo_financing",
  // monvelo, shared reads
  "monvelo_today",
  "monvelo_request_supply_date",
  "monvelo_order_cutoff_at",
  "monvelo_order_financing_status",
] as const;

export type AppRpcName = (typeof APP_RPCS)[number];
