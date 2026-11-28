// usePrefsStore (Spec B §5): the person's theme choice, above tenants, in the
// user-level MMKV instance (`u-<userId>`). `null` means "the role default"
// (ruling 2026-11-27). Until a user is bound it lives in memory only.
import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { createBindableStorage } from "@/shared/storage/bindable-storage";
import { registerReset } from "@/shared/storage/reset-registry";
import type { ThemeName } from "@/shared/tokens";

export const prefsStorage = createBindableStorage();

type PrefsState = {
  theme: ThemeName | null;
  setTheme: (t: ThemeName) => void;
  clearTheme: () => void;
};

export const usePrefsStore = create<PrefsState>()(
  persist(
    (set) => ({
      theme: null,
      setTheme: (theme) => set({ theme }),
      clearTheme: () => set({ theme: null }),
    }),
    {
      name: "shell.prefs",
      storage: createJSONStorage(() => prefsStorage.storage),
      partialize: (s) => ({ theme: s.theme }),
      skipHydration: true,
    },
  ),
);

// Detach first: the saved choice stays in the user's namespace for their next sign-in.
registerReset("session", "shell.prefs", () => {
  prefsStorage.unbind();
  usePrefsStore.setState({ theme: null });
});
