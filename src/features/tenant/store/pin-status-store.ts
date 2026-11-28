// usePinStatusStore (§5.2.2, G8): the active membership's PIN state from the
// server, and whether this session has passed the gate. Memory; reset on a
// tenant switch, because each membership has its own PIN.
import { create } from "zustand";
import { registerReset } from "@/shared/storage/reset-registry";

type PinStatusState = {
  loaded: boolean;
  tenantUserId: string | null;
  pinSet: boolean;
  lockedUntil: string | null;
  attemptsRemaining: number | null;
  unlocked: boolean;
  setStatus: (s: { tenantUserId: string; pinSet: boolean; lockedUntil: string | null }) => void;
  setAttempts: (attemptsRemaining: number | null, lockedUntil: string | null) => void;
  unlock: () => void;
};

const empty = { loaded: false, tenantUserId: null, pinSet: false, lockedUntil: null, attemptsRemaining: null, unlocked: false };

export const usePinStatusStore = create<PinStatusState>((set) => ({
  ...empty,
  setStatus: (s) => set({ loaded: true, ...s }),
  setAttempts: (attemptsRemaining, lockedUntil) => set({ attemptsRemaining, lockedUntil }),
  unlock: () => set({ unlocked: true, pinSet: true, attemptsRemaining: null, lockedUntil: null }),
}));

export const selectIsLocked = (now: number) => (s: PinStatusState) => s.lockedUntil !== null && Date.parse(s.lockedUntil) > now;

registerReset("tenant", "tenant.pin-status", () => usePinStatusStore.setState(empty));
