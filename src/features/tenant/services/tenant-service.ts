// Memberships read under RLS, the tenant switch, and the one existence check
// the §9.3 routing needs from Monvelo (an ACTIVE agent membership).
import { supabase } from "@/shared/network/supabase";
import { rpc } from "@/shared/network/rpc";
import { newIdempotencyKey } from "@/shared/network/idempotency";
import type { Result } from "@/shared/network/errors";
import { networkError } from "@/shared/network/errors";
import { tenantRoleSchema, type Membership } from "../types";

export async function readMemberships(userId: string): Promise<Result<Membership[]>> {
  const { data, error } = await supabase()
    .from("tenant_users")
    .select("id, tenant_id, role, tenants!inner(code, name)")
    .eq("profile_id", userId)
    .eq("status", "ACTIVE");
  if (error) return { ok: false, error: networkError(error.message) };
  return {
    ok: true,
    data: (data ?? []).map((r) => {
      const t = (Array.isArray(r.tenants) ? r.tenants[0] : r.tenants) as { code: string; name: string };
      return { tenantUserId: r.id, tenantId: r.tenant_id, code: t.code, name: t.name, role: tenantRoleSchema.parse(r.role) };
    }),
  };
}

export async function hasMonveloAgentMembership(userId: string): Promise<boolean> {
  const { data, error } = await supabase()
    .from("monvelo_agent_members")
    .select("agent_id")
    .eq("profile_id", userId)
    .eq("status", "ACTIVE")
    .limit(1);
  return !error && (data?.length ?? 0) > 0;
}

/** set_active_tenant proposes a tenant; the database checks the membership (Spec A §9). */
export async function setActiveTenant(tenantId: string): Promise<Result<null>> {
  const res = await rpc("set_active_tenant", { p_idempotency_key: newIdempotencyKey(), p_tenant_id: tenantId });
  return res.ok ? { ok: true, data: null } : res;
}
