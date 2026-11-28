// Spec B §9.3, as a pure decision. Claims are hints: they choose a screen,
// and the database re-checks every call made from it.
import type { Claims } from "@/features/auth";
import type { AccessRoute } from "../types";

export type AccessFacts = {
  signedIn: boolean;
  claims: Claims;
  invitationCount: number;
  hasAgentMembership: boolean;
};

export function decideAccess(f: AccessFacts): AccessRoute {
  if (!f.signedIn) return "sign-in";
  if (f.claims.activeTenantId) return "pin";
  if (f.invitationCount > 0) return "onboarding";
  if (f.hasAgentMembership) return "agent";
  if (f.claims.platformRole) return "use-web";
  return "no-access";
}
