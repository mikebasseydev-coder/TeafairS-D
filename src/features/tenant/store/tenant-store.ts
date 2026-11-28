// useTenantStore (Spec B §5, §5.2.2): the person's ACTIVE memberships, read
// under RLS, and the last active tenant as a hint. Only the hint is
// persisted, in the user-level MMKV instance (`u-<userId>`).
import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { createBindableStorage } from "@/shared/storage/bindable-storage";
import { registerReset } from "@/shared/storage/reset-registry";
import type { Membership } from "../types";

export const tenantStorage = createBindableStorage();

type TenantState = {
  memberships: Membership[];
  lastActiveTenantId: string | null;
  setMemberships: (m: Membership[]) => void;
  setLastActive: (tenantId: string | null) => void;
};

export const useTenantStore = create<TenantState>()(
  persist(
    (set) => ({
      memberships: [],
      lastActiveTenantId: null,
      setMemberships: (memberships) => set({ memberships }),
      setLastActive: (lastActiveTenantId) => set({ lastActiveTenantId }),
    }),
    {
      name: "tenant.tenant",
      storage: createJSONStorage(() => tenantStorage.storage),
      partialize: (s) => ({ lastActiveTenantId: s.lastActiveTenantId }),
      skipHydration: true,
    },
  ),
);

export const selectMembership = (tenantId: string | null) => (s: TenantState) =>
  s.memberships.find((m) => m.tenantId === tenantId) ?? null;

registerReset("session", "tenant.tenant", () => {
  tenantStorage.unbind(); // detach first, so clearing memory never reaches the user's MMKV
  useTenantStore.setState({ memberships: [], lastActiveTenantId: null });
});
