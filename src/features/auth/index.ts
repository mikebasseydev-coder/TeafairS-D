// The auth feature's public surface (Spec B §3, §5.2.1).
export { decodeClaims, type Claims } from "./services/claims";
export { refreshSession, signOut, readOwnProfile, type OwnProfile } from "./services/auth-service";
export { useSessionStore, type SessionStatus } from "./store/session-store";
export { useAuthBootstrap } from "./hooks/use-auth-bootstrap";
export { useSignOut } from "./hooks/use-sign-out";
export { useSessionStatus, useUserId, useClaims, useActiveRole } from "./hooks/use-session";
export { SignInScreen } from "./screens/SignInScreen";
