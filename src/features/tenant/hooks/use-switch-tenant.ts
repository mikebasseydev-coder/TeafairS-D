// Tenant switch (Spec B §5, §9.4): set_active_tenant → refresh → reset every
// tenant store. The switcher UI and the queue check arrive in B3 and B4.
import { useCallback, useState } from "react";
import { refreshSession } from "@/features/auth";
import { runResets } from "@/shared/storage/reset-registry";
import { setActiveTenant } from "../services/tenant-service";
import { sentence } from "../services/pin-policy";

export function useSwitchTenant() {
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const switchTo = useCallback(async (tenantId: string) => {
    setBusy(true);
    setFailure(null);
    const res = await setActiveTenant(tenantId);
    if (res.ok) {
      await refreshSession();
      await runResets("tenant");
    } else setFailure(sentence(res.error.message));
    setBusy(false);
    return res.ok;
  }, []);
  return { switchTo, busy, failure };
}
