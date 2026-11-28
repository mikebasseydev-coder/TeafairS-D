import { useClaims } from "@/features/auth";
import { usePinStatusStore } from "../store/pin-status-store";
import { selectMembership, useTenantStore } from "../store/tenant-store";

export const usePinUnlocked = () => usePinStatusStore((s) => s.unlocked);
export const useMemberships = () => useTenantStore((s) => s.memberships);

export function useActiveMembership() {
  const { activeTenantId } = useClaims();
  return useTenantStore(selectMembership(activeTenantId));
}
