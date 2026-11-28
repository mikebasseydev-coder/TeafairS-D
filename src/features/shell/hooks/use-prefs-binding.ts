// Binds the prefs store to the signed-in user's own MMKV instance and loads
// their saved choice.
import { useEffect } from "react";
import { useUserId } from "@/features/auth";
import { namespaceId, openUserStore } from "@/shared/storage/mmkv";
import { log } from "@/shared/observability/log";
import { prefsStorage, usePrefsStore } from "../store/prefs-store";

export function usePrefsBinding(): void {
  const userId = useUserId();
  useEffect(() => {
    if (!userId) return;
    const ns = namespaceId(userId);
    if (prefsStorage.boundTo() === ns) return;
    (async () => {
      prefsStorage.bind(await openUserStore(userId), ns);
      await usePrefsStore.persist.rehydrate();
    })().catch(() => log.warn("shell.prefs_binding_failed"));
  }, [userId]);
}
