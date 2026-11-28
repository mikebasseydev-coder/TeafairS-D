// Binds the user-level tenant store once a person is signed in, and loads
// their memberships. Detaching on sign-out is the reset's job.
import { useEffect } from "react";
import { useClaims, useUserId } from "@/features/auth";
import { namespaceId, openUserStore } from "@/shared/storage/mmkv";
import { log } from "@/shared/observability/log";
import { readMemberships } from "../services/tenant-service";
import { tenantStorage, useTenantStore } from "../store/tenant-store";

export function useTenantBinding(): void {
  const userId = useUserId();
  const { activeTenantId, tenantIds } = useClaims();
  const tenantKey = tenantIds.join(",");

  useEffect(() => {
    if (!userId) return;
    let live = true;
    (async () => {
      const ns = namespaceId(userId);
      if (tenantStorage.boundTo() !== ns) {
        tenantStorage.bind(await openUserStore(userId), ns);
        await useTenantStore.persist.rehydrate();
      }
      const res = await readMemberships(userId);
      if (!live) return;
      if (res.ok) useTenantStore.getState().setMemberships(res.data);
      else log.warn("tenant.memberships_failed", { code: res.error.code });
    })().catch(() => log.warn("tenant.binding_failed"));
    return () => {
      live = false;
    };
  }, [userId, tenantKey]);

  useEffect(() => {
    if (userId && activeTenantId) useTenantStore.getState().setLastActive(activeTenantId);
  }, [userId, activeTenantId]);
}
