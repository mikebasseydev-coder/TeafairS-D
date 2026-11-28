import { useSessionStore, selectActiveRole, selectClaims, selectUserId } from "../store/session-store";

export const useSessionStatus = () => useSessionStore((s) => s.status);
export const useUserId = () => useSessionStore(selectUserId);
export const useClaims = () => useSessionStore(selectClaims);
export const useActiveRole = () => useSessionStore(selectActiveRole);
