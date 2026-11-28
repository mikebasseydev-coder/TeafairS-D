// Where the signed-in person goes (Spec B §9.3). It reads invitations and the
// Monvelo agent membership only when there is no active tenant.
import { useEffect, useState } from "react";
import { useClaims, useSessionStatus, useUserId } from "@/features/auth";
import { decideAccess } from "../services/access";
import { listInvitations } from "../services/invitations-service";
import { hasMonveloAgentMembership } from "../services/tenant-service";
import { useInvitationStore } from "../store/invitation-store";
import type { AccessRoute } from "../types";

export function useAccess(): { ready: boolean; route: AccessRoute } {
  const status = useSessionStatus();
  const userId = useUserId();
  const claims = useClaims();
  const invitations = useInvitationStore();
  const [agent, setAgent] = useState<{ userId: string; member: boolean } | null>(null);
  const needsFacts = status === "signedIn" && !claims.activeTenantId;

  useEffect(() => {
    if (!needsFacts || !userId) return;
    let live = true;
    const inv = useInvitationStore.getState();
    inv.loading();
    listInvitations().then((r) => (r.ok ? inv.loaded(r.data) : inv.failed(r.error)));
    hasMonveloAgentMembership(userId).then((member) => live && setAgent({ userId, member }));
    return () => {
      live = false;
    };
  }, [needsFacts, userId]);

  if (status === "booting") return { ready: false, route: "sign-in" };
  const factsReady = !needsFacts || (invitations.status !== "loading" && invitations.status !== "idle" && agent?.userId === userId);
  return {
    ready: factsReady,
    route: decideAccess({
      signedIn: status === "signedIn",
      claims,
      invitationCount: invitations.items.length,
      hasAgentMembership: agent?.member ?? false,
    }),
  };
}
