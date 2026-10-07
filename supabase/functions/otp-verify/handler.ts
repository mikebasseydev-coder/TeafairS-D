// Spec A §6.11 — verify the shop-owner OTP. verify_otp compares the hash,
// counts failures and consumes the challenge; it returns its verdict rather
// than raising, so a wrong code still counts. Each attempt needs a new
// idempotency key: a reused key replays the earlier verdict.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  challenge_id: z.string().uuid(),
  code: z.string().regex(/^\d{6}$/, "code must be 6 digits"),
});

type Reason = "INVALID" | "EXPIRED" | "LOCKED" | "CONSUMED";
type Verdict = { verified: boolean; reason?: Reason; attempts_left?: number };

const MESSAGES: Record<Reason, string> = {
  INVALID: "That code is wrong.",
  EXPIRED: "That code has expired. Request a new one.",
  LOCKED: "Too many wrong codes. Request a new one.",
  CONSUMED: "That code has already been used.",
};

export function createOtpVerifyHandler(deps: UserGatewayDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const verdict = await rpc<Verdict>("verify_otp", {
      p_idempotency_key: body.idempotency_key,
      p_challenge_id: body.challenge_id,
      p_code: body.code,
    });
    if (!verdict.verified) {
      const reason = verdict.reason ?? "INVALID";
      throw new GatewayError(422, `OTP_${reason}`, MESSAGES[reason], {
        attempts_left: verdict.attempts_left ?? null,
      });
    }
    return { verified: true, challenge_id: body.challenge_id };
  }, deps);
}
