// Every write takes a UUID v4 key made by the caller (Spec B §7, §8): at
// enqueue for queued writes, and afresh on every attempt for anything with a
// PIN or a code, because the stored request omits the secret and a reused
// key would replay the first answer.
import * as Crypto from "expo-crypto";

export const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function newIdempotencyKey(): string {
  return Crypto.randomUUID();
}
