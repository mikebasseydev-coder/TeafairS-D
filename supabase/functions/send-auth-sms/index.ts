import { hookVerifierFromEnv } from "../_shared/auth/hook.ts";
import { serviceRpc } from "../_shared/core/db.ts";
import { observe } from "../_shared/core/observability.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { createSendAuthSmsHandler } from "./handler.ts";

// system-flavoured (§3.4): Supabase Auth calls this before any session
// exists, so the allow-list check runs with the service-role key.
const verifyHook = hookVerifierFromEnv("SEND_SMS_HOOK_SECRET");
const rpc = serviceRpc();

Deno.serve(observe("send-auth-sms", createSendAuthSmsHandler({
  verifyHook,
  isAllowed: (userId, phone) => rpc<boolean>("auth_sms_allowed", { p_user_id: userId, p_phone: phone }),
  sendMessage: messageRouterFromEnv(rpc),
  smsFallback: Deno.env.get("AUTH_OTP_SMS_FALLBACK") === "true",
})));
