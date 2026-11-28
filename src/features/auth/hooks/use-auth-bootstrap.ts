// Mirrors the Supabase session into useSessionStore, and claims the device
// for the signed-in user (Spec B §5: another user's namespaces are cleared).
import { useEffect } from "react";
import { claimDevice } from "@/shared/storage/device";
import { log } from "@/shared/observability/log";
import { currentSession, onSessionChange } from "../services/auth-service";
import { useSessionStore } from "../store/session-store";

export function useAuthBootstrap(): void {
  useEffect(() => {
    const apply = (token: string | null) => {
      useSessionStore.getState().setAccessToken(token);
      const userId = useSessionStore.getState().userId;
      if (userId) claimDevice(userId).catch(() => log.warn("auth.claim_device_failed"));
    };
    let stop = () => {};
    try {
      currentSession()
        .then((s) => apply(s?.access_token ?? null))
        .catch(() => apply(null));
      stop = onSessionChange((s) => apply(s?.access_token ?? null));
    } catch {
      // no Supabase configuration (the gallery runs without one)
      apply(null);
    }
    return () => stop();
  }, []);
}
