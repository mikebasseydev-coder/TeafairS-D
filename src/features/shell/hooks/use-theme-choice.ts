// The theme the app renders: the saved choice, else the active role's default
// (Spec B §4.2: daylight for ZSA, ASA, TM, RETAIL_SHOP_OWNER, POS_AGENT).
import { useActiveRole } from "@/features/auth";
import { defaultThemeForRole, effectiveTheme, type ThemeName } from "@/shared/tokens";
import { usePrefsStore } from "../store/prefs-store";

export function useThemeChoice() {
  const role = useActiveRole();
  const choice = usePrefsStore((s) => s.theme);
  return {
    theme: effectiveTheme(choice, role) as ThemeName,
    choice,
    roleDefault: defaultThemeForRole(role),
    setTheme: usePrefsStore.getState().setTheme,
    clearTheme: usePrefsStore.getState().clearTheme,
  };
}
