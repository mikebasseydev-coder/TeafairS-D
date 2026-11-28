// The tenant feature's public surface (Spec B §3, §5.2.2).
export type { AccessRoute, Invitation, Membership } from "./types";
export { ROLE_LABEL } from "./components/role-label";
export { pinPolicyRefusal } from "./services/pin-policy";
export { decideAccess } from "./services/access";
export { useTenantBinding } from "./hooks/use-tenant-binding";
export { useAccess } from "./hooks/use-access";
export { useSwitchTenant } from "./hooks/use-switch-tenant";
export { usePinUnlocked, useMemberships, useActiveMembership } from "./hooks/use-tenant";
export { OnboardingScreen } from "./screens/OnboardingScreen";
export { PinGateScreen } from "./screens/PinGateScreen";
export { PinChangeScreen } from "./screens/PinChangeScreen";
export { AccessStateScreen } from "./screens/AccessStateScreen";
