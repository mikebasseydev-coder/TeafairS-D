// Addendum A5 §5.2 — the 4-digit delivery code and the gateway-side plumbing
// shared by order-dispatch and order-delivery-pin.
import type { Rpc } from "../core/db.ts";
import { deliveryCodeTemplate, MessageDeliveryError, type MessageSender } from "../messaging/router.ts";

// Uniform 4-digit codes: reject the biased tail of the 32-bit draw.
const RANGE = 10_000;
const LIMIT = 2 ** 32 - (2 ** 32 % RANGE);

export function generateDeliveryPin(): string {
  const draw = new Uint32Array(1);
  do crypto.getRandomValues(draw); while (draw[0] >= LIMIT);
  return String(draw[0] % RANGE).padStart(4, "0");
}

export const deliveryCodeSms = (reference: string, pin: string): string =>
  `Your Teafair order ${reference} is on its way. Give this delivery code to the rider: ${pin}.`;

/** A stable uuid derived from the request key, so mark_delivery_pin_sent has its own idempotency key. */
export async function derivedKey(key: string, label: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${label}:${key}`)));
  const b = digest.slice(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export type CodeDelivery = { delivery_code_sent: boolean; channel: "WHATSAPP" | "SMS" | null };

/**
 * Sends the code (only when the RPC handed back a phone, i.e. not a replay),
 * then records the send. A failed send leaves the order IN_TRANSIT and reports
 * delivery_code_sent false; recovery is a resend. The phone and PIN never leave.
 */
export async function sendDeliveryCode(args: {
  rpc: Rpc;
  send: MessageSender;
  purpose: "DELIVERY_CODE" | "DELIVERY_CODE_RESEND";
  idempotencyKey: string;
  orderId: string;
  reference: string;
  phone: string | undefined;
  pin: string;
  gatewayProof: string;
  /** The caller's active tenant (R18), already proved equal to the order's by the RPC. */
  tenantId: string | null;
}): Promise<CodeDelivery> {
  if (!args.phone) return { delivery_code_sent: false, channel: null };
  let channel: "WHATSAPP" | "SMS";
  try {
    channel = (await args.send(args.phone, {
      purpose: args.purpose,
      template: deliveryCodeTemplate(args.reference, args.pin),
      smsText: deliveryCodeSms(args.reference, args.pin),
      relatedId: args.orderId,
      tenantId: args.tenantId ?? undefined,
    })).channel;
  } catch (e) {
    if (e instanceof MessageDeliveryError) return { delivery_code_sent: false, channel: null };
    throw e;
  }
  try {
    await args.rpc("mark_delivery_pin_sent", {
      p_idempotency_key: await derivedKey(args.idempotencyKey, "pin-sent"),
      p_order_id: args.orderId,
      p_channel: channel,
      p_gateway_proof: args.gatewayProof,
    });
  } catch {
    // The buyer has the code; failing the request would only invite a second send.
    console.error("mark_delivery_pin_sent failed after a successful send");
  }
  return { delivery_code_sent: true, channel };
}
