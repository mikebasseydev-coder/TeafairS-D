// Claims are hints (Spec B §9.2): they pick a route and never authorise
// anything. The database re-checks every call.
import { PLATFORM_ROLES, TENANT_ROLES, type PlatformRole, type TenantRole } from "@/shared/tokens";

export type Claims = {
  userId: string | null;
  tenantIds: string[];
  activeTenantId: string | null;
  tenantRole: TenantRole | null;
  platformRole: PlatformRole | null;
  expiresAt: number | null;
};

const EMPTY: Claims = { userId: null, tenantIds: [], activeTenantId: null, tenantRole: null, platformRole: null, expiresAt: null };

function base64UrlDecode(s: string): string {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=");
  if (typeof atob === "function") {
    const bin = atob(b64);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  }
  return Buffer.from(b64, "base64").toString("utf8");
}

const asString = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null);

/** Decodes the access token's payload without verifying it. Anything malformed decodes to no claims. */
export function decodeClaims(accessToken: string | null | undefined): Claims {
  if (!accessToken) return EMPTY;
  const parts = accessToken.split(".");
  if (parts.length !== 3) return EMPTY;
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(base64UrlDecode(parts[1]));
  } catch {
    return EMPTY;
  }
  if (!payload || typeof payload !== "object") return EMPTY;
  const meta = (payload.app_metadata ?? {}) as Record<string, unknown>;
  const tenantIds = Array.isArray(meta.tenant_ids) ? meta.tenant_ids.filter((x): x is string => typeof x === "string") : [];
  const role = asString(meta.tenant_role);
  const platform = asString(meta.platform_role);
  return {
    userId: asString(payload.sub),
    tenantIds,
    activeTenantId: asString(meta.active_tenant_id),
    tenantRole: role && (TENANT_ROLES as readonly string[]).includes(role) ? (role as TenantRole) : null,
    platformRole: platform && (PLATFORM_ROLES as readonly string[]).includes(platform) ? (platform as PlatformRole) : null,
    expiresAt: typeof payload.exp === "number" ? payload.exp : null,
  };
}
