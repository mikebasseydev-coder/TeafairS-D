// WhatsApp-first message router (addendum A5 §7). Tries the Meta WhatsApp Cloud
// API under a timeout, falls back to SMS, and logs every attempt that ends a
// send. A log entry never holds the message, the code, the full phone number
// or any secret.
import { traced } from "../core/observability.ts";
import type { Rpc } from "../core/db.ts";
import { serviceRpc } from "../core/db.ts";
import type { SmsSender } from "../core/sms.ts";
import { smsSenderFromEnv } from "../core/sms.ts";
import {
  sendWhatsAppTemplate,
  type WhatsAppConfig,
  WhatsAppError,
  whatsAppConfigFromEnv,
  type WhatsAppTemplate,
} from "./whatsapp.ts";

export type Purpose =
  | "OTP"
  | "DELIVERY_CODE"
  | "DELIVERY_CODE_RESEND"
  | "PHONE_VERIFY"
  | "AUTH_OTP"
  | "MONVELO_CONSENT"
  | "MONVELO_DELIVERY";

export type OutboundMessage = {
  purpose: Purpose;
  template: WhatsAppTemplate;
  smsText: string;
  tenantId?: string;
  relatedId?: string;
  /** Never fall back to SMS (PHONE_VERIFY proves the number is on WhatsApp). */
  whatsappOnly?: boolean;
};

export type DeliveryResult = { channel: "WHATSAPP" | "SMS"; sent: true };
export type MessageSender = (to: string, msg: OutboundMessage) => Promise<DeliveryResult>;

export type DeliveryLogEntry = {
  tenantId: string | null;
  purpose: Purpose;
  channel: "WHATSAPP" | "SMS";
  status: "SENT" | "FAILED";
  phoneLast4: string;
  relatedId: string | null;
  whatsappError: string | null;
};

export class MessageDeliveryError extends Error {
  constructor(message = "message could not be delivered") {
    super(message);
    this.name = "MessageDeliveryError";
  }
}

/** Provider error code only: Meta's error.code, or a fixed word. Never raw error text. */
function whatsAppErrorCode(e: unknown): string {
  if (e instanceof WhatsAppError && e.code) return e.code;
  if (e instanceof DOMException && (e.name === "TimeoutError" || e.name === "AbortError")) return "TIMEOUT";
  return e instanceof WhatsAppError ? "HTTP_ERROR" : "NETWORK";
}

export function createMessageRouter(deps: {
  whatsapp: WhatsAppConfig | null;
  sendWhatsApp?: typeof sendWhatsAppTemplate;
  sms: SmsSender;
  log: (entry: DeliveryLogEntry) => Promise<void>;
  timeoutMs?: number;
}): MessageSender {
  const sendWhatsApp = deps.sendWhatsApp ?? sendWhatsAppTemplate;
  const timeoutMs = deps.timeoutMs ?? 15000;

  return async (to, msg) => {
    const base = {
      tenantId: msg.tenantId ?? null,
      purpose: msg.purpose,
      phoneLast4: to.slice(-4),
      relatedId: msg.relatedId ?? null,
    };
    // A failing log must never make a delivered message look failed (or the
    // reverse): swallow it, and print nothing that could carry a secret.
    const record = async (channel: "WHATSAPP" | "SMS", status: "SENT" | "FAILED", whatsappError: string | null = null) => {
      try {
        await deps.log({ ...base, channel, status, whatsappError });
      } catch {
        // intentionally ignored
      }
    };

    let waError: string | null = null;
    if (deps.whatsapp) {
      const signal = AbortSignal.timeout(timeoutMs);
      let abort: (() => void) | undefined;
      try {
        // Race the send against the signal so a transport that ignores it still times out.
        await traced("whatsapp.send", "message.send", { channel: "WHATSAPP", purpose: msg.purpose }, () => Promise.race([
          sendWhatsApp(deps.whatsapp!, to, msg.template, signal),
          new Promise<never>((_, reject) => {
            abort = () => reject(signal.reason);
            signal.addEventListener("abort", abort, { once: true });
          }),
        ]));
        await record("WHATSAPP", "SENT");
        return { channel: "WHATSAPP", sent: true };
      } catch (e) {
        waError = whatsAppErrorCode(e);
        await record("WHATSAPP", "FAILED", waError);
      } finally {
        if (abort) signal.removeEventListener("abort", abort);
      }
    }

    if (msg.whatsappOnly) throw new MessageDeliveryError("WhatsApp delivery failed");
    try {
      await traced("sms.send", "message.send", { channel: "SMS", purpose: msg.purpose }, () => deps.sms(to, msg.smsText));
    } catch {
      await record("SMS", "FAILED");
      throw new MessageDeliveryError("SMS delivery failed");
    }
    await record("SMS", "SENT");
    return { channel: "SMS", sent: true };
  };
}

/** Live wiring: env config, KudiSMS fallback, and the service-only delivery log RPC. */
export function messageRouterFromEnv(rpc: Rpc = serviceRpc()): MessageSender {
  return createMessageRouter({
    whatsapp: whatsAppConfigFromEnv(),
    sms: smsSenderFromEnv(),
    log: async (e) => {
      // log_message_delivery keeps right(p_phone, 4); only the last four digits leave this process
      await rpc("log_message_delivery", {
        p_tenant_id: e.tenantId,
        p_purpose: e.purpose,
        p_channel: e.channel,
        p_status: e.status,
        p_phone: e.phoneLast4,
        p_related_id: e.relatedId,
        p_whatsapp_error: e.whatsappError,
      });
    },
  });
}

export const otpTemplate = (code: string): WhatsAppTemplate => ({
  name: Deno.env.get("WHATSAPP_TEMPLATE_OTP") || "teafair_otp",
  language: "en",
  params: [code],
  kind: "authentication",
});

export const deliveryCodeTemplate = (reference: string, code: string): WhatsAppTemplate => ({
  name: Deno.env.get("WHATSAPP_TEMPLATE_DELIVERY_CODE") || "teafair_delivery_code",
  language: "en",
  params: [reference, code],
});
