import type { TenantRole } from "@/shared/tokens";

/** The words a person sees for a role. Exhaustive: a new role breaks the type check. */
export const ROLE_LABEL: Record<TenantRole, string> = {
  ZSM: "Zonal sales manager",
  TM: "Territory manager",
  ASM: "Area sales manager",
  DSM: "District sales manager",
  DSA: "Direct sales agent",
  ZSA: "Zone street agent",
  ASA: "Area street agent",
  POS_AGENT: "POS agent",
  RETAIL_SHOP_OWNER: "Shop owner",
  CLIENT_SERVICE_MANAGER: "Client service manager",
  TENANT_ADMIN: "Brand administrator",
  LOGISTICS_MANAGER: "Logistics manager",
};
