// Spec A §3.1 step 4 / §5.5. The bcrypt comparison and the lockout counter
// live in public.verify_pin, called with the caller's own JWT: the gateway
// never sees pin_hash and never holds the service-role key.
// A pass also records pin_pass_at, which the PIN-gated RPC itself spends
// through consume_pin_pass(), so skipping this gateway gains nothing.
import { z } from "../core/deps.ts";
import type { Rpc } from "../core/db.ts";
import { GatewayError } from "../core/errors.ts";

export const pinSchema = z.string().regex(/^\d{4}$/, "PIN must be 4 digits");

type PinCheck = { ok: boolean; attempts_left: number; locked_until: string | null };

export async function requirePin(rpc: Rpc, pin: string): Promise<void> {
  const check = await rpc<PinCheck>("verify_pin", { p_pin: pin });
  if (check.ok) return;
  if (check.locked_until) {
    throw new GatewayError(423, "PIN_LOCKED", "Too many wrong PINs. Try again later.", {
      locked_until: check.locked_until,
    });
  }
  throw new GatewayError(403, "PIN_INVALID", "Wrong PIN.", { attempts_left: check.attempts_left });
}
