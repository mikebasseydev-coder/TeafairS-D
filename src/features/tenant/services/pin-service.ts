// The membership PIN (migration 20261125130000; verify_pin from 20261007120100).
// A PIN is never logged, stored or queued. A wrong current PIN comes back as
// data, so every attempt takes a fresh key (Spec B §8, §9.5).
import { rpc } from "@/shared/network/rpc";
import { newIdempotencyKey } from "@/shared/network/idempotency";
import type { Result } from "@/shared/network/errors";
import { pinChangeReplySchema, pinCheckSchema, pinStatusSchema, type PinChangeReply, type PinCheck, type PinStatus } from "../types";

export async function getPinStatus(): Promise<Result<PinStatus>> {
  const res = await rpc("get_my_pin_status", {});
  return res.ok ? { ok: true, data: pinStatusSchema.parse(res.data) } : res;
}

export async function setPin(pin: string): Promise<Result<null>> {
  const res = await rpc("set_tenant_pin", { p_idempotency_key: newIdempotencyKey(), p_new_pin: pin });
  return res.ok ? { ok: true, data: null } : res;
}

export async function changePin(currentPin: string, newPin: string): Promise<Result<PinChangeReply>> {
  const res = await rpc("change_tenant_pin", { p_idempotency_key: newIdempotencyKey(), p_current_pin: currentPin, p_new_pin: newPin });
  return res.ok ? { ok: true, data: pinChangeReplySchema.parse(res.data) } : res;
}

/** The guard: no key, never queued; a replay must never re-grant a pass. */
export async function verifyPin(pin: string): Promise<Result<PinCheck>> {
  const res = await rpc("verify_pin", { p_pin: pin });
  return res.ok ? { ok: true, data: pinCheckSchema.parse(res.data) } : res;
}
