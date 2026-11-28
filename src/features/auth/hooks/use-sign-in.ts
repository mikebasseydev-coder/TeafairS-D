// The email-first flow (Spec B §9.1): email → code → session. The store holds
// the typed values; this hook sends them and wipes the code on every submit.
import { useCallback, useEffect, useState } from "react";
import { requestCode, verifyCode, type AuthFailure } from "../services/auth-service";
import { useOtpStore } from "../store/otp-store";
import { codeSchema, emailSchema } from "../types";

type Busy = "idle" | "sending" | "verifying";

export function useSignIn() {
  const otp = useOtpStore();
  const [busy, setBusy] = useState<Busy>("idle");
  const [failure, setFailure] = useState<AuthFailure | null>(null);
  const [inputError, setInputError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (otp.resendAvailableAt === null || now >= otp.resendAvailableAt) return;
    const t = setTimeout(() => setNow(Date.now()), 1000);
    return () => clearTimeout(t);
  }, [otp.resendAvailableAt, now]);

  const send = useCallback(async (raw: string) => {
    setFailure(null);
    const parsed = emailSchema.safeParse(raw);
    if (!parsed.success) return setInputError(parsed.error.issues[0]?.message ?? "Enter a valid email address.");
    setInputError(null);
    setBusy("sending");
    const res = await requestCode(parsed.data);
    setBusy("idle");
    if (res.ok) {
      const t = Date.now();
      setNow(t);
      useOtpStore.getState().codeSent(parsed.data, t);
    } else setFailure(res.failure);
  }, []);

  const verify = useCallback(async () => {
    const { email, code } = useOtpStore.getState();
    setFailure(null);
    if (!codeSchema.safeParse(code).success) return setInputError("The code is six digits.");
    setInputError(null);
    setBusy("verifying");
    const res = await verifyCode(email, code);
    setBusy("idle");
    if (res.ok) useOtpStore.getState().wipe();
    else {
      useOtpStore.getState().clearCode();
      setFailure(res.failure);
    }
    return res.ok;
  }, []);

  const secondsToResend = otp.resendAvailableAt === null ? 0 : Math.max(0, Math.ceil((otp.resendAvailableAt - now) / 1000));

  return {
    step: otp.step,
    email: otp.email,
    code: otp.code,
    setEmail: otp.setEmail,
    setCode: otp.setCode,
    backToEmail: otp.backToEmail,
    send,
    resend: () => send(otp.email),
    verify,
    busy,
    failure,
    inputError,
    secondsToResend,
  };
}
