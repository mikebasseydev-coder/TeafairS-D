// Invitations (migration 20261125130000). Accept and decline are online only,
// with a fresh key per attempt (Spec B §8).
import { z } from "zod";
import { rpc } from "@/shared/network/rpc";
import { newIdempotencyKey } from "@/shared/network/idempotency";
import type { Result } from "@/shared/network/errors";
import { invitationSchema, type Invitation } from "../types";

export async function listInvitations(): Promise<Result<Invitation[]>> {
  const res = await rpc("list_my_invitations", {});
  if (!res.ok) return res;
  return { ok: true, data: z.array(invitationSchema).parse(res.data) };
}

export async function acceptInvitation(tenantUserId: string): Promise<Result<{ refreshSession: boolean }>> {
  const res = await rpc("accept_tenant_invitation", { p_idempotency_key: newIdempotencyKey(), p_tenant_user_id: tenantUserId });
  if (!res.ok) return res;
  const reply = z.object({ refresh_session: z.boolean().optional() }).parse(res.data);
  return { ok: true, data: { refreshSession: reply.refresh_session ?? true } };
}

export async function declineInvitation(tenantUserId: string): Promise<Result<null>> {
  const res = await rpc("decline_tenant_invitation", { p_idempotency_key: newIdempotencyKey(), p_tenant_user_id: tenantUserId });
  return res.ok ? { ok: true, data: null } : res;
}
