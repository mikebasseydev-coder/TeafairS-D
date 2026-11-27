// The app's user gateways (Spec B §6.1, Surface "App"), each body mirroring
// the gateway's own Zod schema in supabase/functions/<name>/handler.ts.
// TeafairWeb-only gateways (order-dispute-evidence, contact-report-upload),
// the storefront's public gateways and the system functions are absent on
// purpose: the app never calls them.
import { z } from "zod";

const uuid = z.string().uuid();
/** UUID v4 (RFC 4122 variant), as `idempotencyKeyV4` in _shared/core/validate.ts. */
const uuidV4 = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
const code6 = z.string().regex(/^\d{6}$/);
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const photo = {
  mime_type: z.enum(["image/jpeg", "image/png", "image/webp"]),
  size_bytes: z.number().int().min(1),
};
const account = {
  settlement_account_number: z.string().regex(/^\d{10}$/),
  settlement_bank_code: z.string().trim().min(1).max(16),
};
const money = z
  .number()
  .positive()
  .max(9_999_999_999_999.99)
  .refine((n) => Math.abs(n * 100 - Math.round(n * 100)) < 1e-6, "at most 2 decimals");

export const gatewaySchemas = {
  "otp-issue": z.object({
    idempotency_key: uuid,
    subject_id: uuid,
    purpose: z.enum(["PICKUP_CONFIRM", "POS_SETTLEMENT"]),
  }),
  "otp-verify": z.object({ idempotency_key: uuid, challenge_id: uuid, code: code6 }),
  "order-dispatch": z.object({ idempotency_key: uuid, order_id: uuid, tracking_reference: z.string().max(100).optional() }),
  "order-delivery-pin": z.object({ idempotency_key: uuid, order_id: uuid }),
  "order-delivery-photo": z.object({ idempotency_key: uuid, order_id: uuid, ...photo }),
  "order-delivery-confirm": z.object({
    idempotency_key: uuid,
    order_id: uuid,
    pin: z.string().regex(/^\d{4}$/),
    photo_attachment_id: uuid.optional(),
  }),
  "support-staff-attachment": z.object({ idempotency_key: uuid, ticket_id: uuid, ...photo }),
  "monvelo-agent-register": z.discriminatedUnion("action", [
    z.object({
      idempotency_key: uuidV4,
      action: z.literal("register"),
      business_name: z.string().trim().min(1).max(200),
      pos_network: z.enum(["MONIEPOINT", "OPAY", "PALMPAY"]),
      network_agent_id: z.string().trim().min(1).max(64),
      contact_phone: z.string().trim().min(7).max(24),
      latitude: z.number().min(-90).max(90),
      longitude: z.number().min(-180).max(180),
      address_text: z.string().trim().min(1).max(500),
      network_kyc_reference: z.string().trim().min(1).max(100),
      ...account,
    }),
    z.object({ idempotency_key: uuidV4, action: z.literal("change_settlement"), agent_id: uuid, ...account }),
  ]),
  "monvelo-shop-consent": z.discriminatedUnion("action", [
    z.object({ idempotency_key: uuid, action: z.literal("start"), shop_id: uuid, area_id: uuid }),
    z.object({ idempotency_key: uuid, action: z.literal("enrol"), challenge_id: uuid, code: code6 }),
    z.object({ idempotency_key: uuid, action: z.literal("start_policy"), shop_id: uuid, area_id: uuid }),
    z.object({
      idempotency_key: uuid,
      action: z.literal("submit_policy"),
      challenge_id: uuid,
      code: code6,
      insurer_name: z.string().trim().min(1).max(200),
      policy_number: z.string().trim().min(1).max(64),
      covers_fire_perils: z.boolean(),
      covers_burglary: z.boolean(),
      sum_insured: z.number().positive().max(9_999_999_999_999),
      lender_interest_endorsed: z.boolean(),
      starts_on: isoDate,
      expires_on: isoDate,
      document_path: z.string().min(1).max(300),
    }),
  ]),
  "monvelo-fund": z.object({ idempotency_key: uuid, financing_id: uuid, agent_id: uuid }),
  "monvelo-confirm-delivery": z.discriminatedUnion("action", [
    z.object({ idempotency_key: uuid, action: z.literal("start"), financing_id: uuid }),
    z.object({ idempotency_key: uuid, action: z.literal("confirm"), challenge_id: uuid, code: code6 }),
  ]),
  "monvelo-confirm-repayment": z.discriminatedUnion("action", [
    z.object({ idempotency_key: uuid, action: z.literal("record"), financing_id: uuid, agent_id: uuid, amount: money }),
    z.object({ idempotency_key: uuid, action: z.literal("confirm"), challenge_id: uuid, code: code6 }),
  ]),
  "monvelo-cover-upload": z.object({
    purpose: z.enum(["SHOP_POLICY", "CLAIM_EVIDENCE"]),
    subject_id: uuid,
    content_type: z.enum(["application/pdf", "image/jpeg", "image/png"]),
    byte_length: z.number().int().min(1).max(10_485_760),
  }),
} as const;

export type GatewayName = keyof typeof gatewaySchemas;
export type GatewayBody<G extends GatewayName> = z.input<(typeof gatewaySchemas)[G]>;
export const GATEWAY_NAMES = Object.keys(gatewaySchemas) as GatewayName[];
