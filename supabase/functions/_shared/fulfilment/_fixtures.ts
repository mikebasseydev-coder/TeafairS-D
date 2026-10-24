// Test helpers for the code-sending gateways.
import type { Rpc } from "../core/db.ts";
import { MessageDeliveryError, type MessageSender, type OutboundMessage } from "../messaging/router.ts";

export const KEY = "c0000000-0000-0000-0000-000000000001";
export const ORDER = "d0000000-0000-0000-0000-000000000001";
export const PHONE = "+2348012345678";
export const PIN = "4821";
export const SECRET = "gw-secret-value";
export const REF = "TF-1234";

export function sendSetup(opts: { reply: Record<string, unknown>; fail?: boolean }) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const sends: Array<[string, OutboundMessage]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve((fn === "mark_delivery_pin_sent" ? { order_id: ORDER } : opts.reply) as T);
  };
  const sendMessage: MessageSender = (to, msg) => {
    sends.push([to, msg]);
    if (opts.fail) return Promise.reject(new MessageDeliveryError());
    return Promise.resolve({ channel: "WHATSAPP", sent: true });
  };
  const base = {
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    sendMessage,
    generatePin: () => PIN,
    gatewaySecret: SECRET,
  };
  return { base, calls, sends };
}

export const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));
