// Spec B §5: a signed-out user's MMKV namespaces stay on the device,
// encrypted, and are cleared at the next sign-in of a different user. They
// are cleared by forgetting that user's key (Tier 1), so nothing of theirs can
// be read again, whatever files remain.
import { forgetMmkvKey, secureGet, secureSet } from "./secure";
import { forgetOpenStores } from "./mmkv";

const LAST_USER = "device.last-user";

export async function claimDevice(userId: string): Promise<{ previousUserCleared: boolean }> {
  const last = await secureGet(LAST_USER);
  let previousUserCleared = false;
  if (last && last !== userId) {
    forgetOpenStores();
    await forgetMmkvKey(last);
    previousUserCleared = true;
  }
  if (last !== userId) await secureSet(LAST_USER, userId);
  return { previousUserCleared };
}
