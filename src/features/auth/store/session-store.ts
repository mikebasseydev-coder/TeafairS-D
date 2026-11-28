// useSessionStore (Spec B §5): what the app knows about the signed-in person.
// The tokens themselves live only in Tier 1 (supabase-js over secure.ts);
// this store holds the decoded claims, which are hints for routing only.
import { create } from "zustand";
import { registerReset } from "@/shared/storage/reset-registry";
import { decodeClaims, type Claims } from "../services/claims";

export type SessionStatus = "booting" | "signedOut" | "signedIn";

type SessionState = {
  status: SessionStatus;
  userId: string | null;
  claims: Claims;
  setAccessToken: (accessToken: string | null) => void;
};

const signedOut = () => ({ status: "signedOut" as const, userId: null, claims: decodeClaims(null) });

export const useSessionStore = create<SessionState>((set) => ({
  status: "booting",
  userId: null,
  claims: decodeClaims(null),
  setAccessToken: (accessToken) => {
    const claims = decodeClaims(accessToken);
    set(accessToken && claims.userId ? { status: "signedIn", userId: claims.userId, claims } : signedOut());
  },
}));

export const selectUserId = (s: SessionState) => s.userId;
export const selectClaims = (s: SessionState) => s.claims;
export const selectActiveRole = (s: SessionState) => s.claims.tenantRole;

registerReset("session", "auth.session", () => useSessionStore.setState(signedOut()));
