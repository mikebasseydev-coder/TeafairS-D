// The role default and the user's override (ruling 2026-11-27, Spec B §4.2).
import type { ThemeName } from "./semantic";

export const TENANT_ROLES = [
  "ZSM",
  "TM",
  "ASM",
  "DSM",
  "DSA",
  "ZSA",
  "ASA",
  "POS_AGENT",
  "RETAIL_SHOP_OWNER",
  "CLIENT_SERVICE_MANAGER",
  "TENANT_ADMIN",
  "LOGISTICS_MANAGER",
] as const;
export type TenantRole = (typeof TENANT_ROLES)[number];

export const PLATFORM_ROLES = ["PLATFORM_SUPER_ADMIN", "MONVELO_OPERATOR", "MONVELO_FINANCE"] as const;
export type PlatformRole = (typeof PLATFORM_ROLES)[number];

/** Outdoor field work: high contrast by default. */
const DAYLIGHT_ROLES: ReadonlySet<TenantRole> = new Set(["ZSA", "ASA", "TM", "RETAIL_SHOP_OWNER", "POS_AGENT"]);

/**
 * The theme a membership starts in. `null` (no tenant membership, e.g. a
 * Monvelo agent member) is `standard`. `dark` is never a default: the user
 * chooses it.
 */
export function defaultThemeForRole(role: TenantRole | null | undefined): ThemeName {
  return role && DAYLIGHT_ROLES.has(role) ? "daylight" : "standard";
}

/** The user's saved choice wins in every tenant; clearing it returns to the role default. */
export function effectiveTheme(choice: ThemeName | null | undefined, role: TenantRole | null | undefined): ThemeName {
  return choice ?? defaultThemeForRole(role);
}
