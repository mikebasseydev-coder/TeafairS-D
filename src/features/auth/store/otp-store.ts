// useOtpStore (Spec B §5, Tier 3): the email and the sign-in code while they
// are typed. Never persisted. Wiped on submit, on tenant switch and on
// sign-out; going to the background drops the code only, because the person
// leaves the app to read the email (registerTier3).
import { create } from "zustand";
import { registerTier3 } from "@/shared/storage/tier3";

export const RESEND_COOLDOWN_MS = 60_000;

export type OtpStep = "email" | "code";

type OtpState = {
  step: OtpStep;
  email: string;
  code: string;
  resendAvailableAt: number | null;
  setEmail: (email: string) => void;
  setCode: (code: string) => void;
  codeSent: (email: string, now: number) => void;
  clearCode: () => void;
  backToEmail: () => void;
  wipe: () => void;
};

const empty = { step: "email" as const, email: "", code: "", resendAvailableAt: null };

export const useOtpStore = create<OtpState>((set) => ({
  ...empty,
  setEmail: (email) => set({ email }),
  setCode: (code) => set({ code }),
  codeSent: (email, now) => set({ step: "code", email, code: "", resendAvailableAt: now + RESEND_COOLDOWN_MS }),
  clearCode: () => set({ code: "" }),
  backToEmail: () => set({ step: "email", code: "", resendAvailableAt: null }),
  wipe: () => set(empty),
}));

export const selectCanResend = (now: number) => (s: OtpState) => s.resendAvailableAt !== null && now >= s.resendAvailableAt;

registerTier3("auth.otp", () => useOtpStore.getState().wipe(), { onBackground: () => useOtpStore.getState().clearCode() });
