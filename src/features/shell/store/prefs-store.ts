// usePrefsStore (Spec B §5): the user's theme choice, above tenants. `null`
// means "the role default" (ruling 2026-11-27). B1 keeps it in memory; slice
// B2 binds it to the user-level MMKV instance once a user is signed in.
import { create } from "zustand";
import { registerReset } from "@/shared/storage/reset-registry";
import type { ThemeName } from "@/shared/tokens";

type PrefsState = {
  theme: ThemeName | null;
  setTheme: (t: ThemeName) => void;
  clearTheme: () => void;
};

export const usePrefsStore = create<PrefsState>((set) => ({
  theme: null,
  setTheme: (theme) => set({ theme }),
  clearTheme: () => set({ theme: null }),
}));

registerReset("session", "shell.prefs", () => usePrefsStore.setState({ theme: null }));
