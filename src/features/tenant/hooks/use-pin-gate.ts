// The PIN gate (Spec B §9.5). With no PIN, the person enters four digits twice
// and the client refuses a weak PIN before sending. With a PIN, verify_pin
// unlocks the session. Every submit wipes the Tier 3 buffers.
import { useCallback, useEffect, useState } from "react";
import { getPinStatus, setPin, verifyPin } from "../services/pin-service";
import { pinPolicyRefusal, sentence } from "../services/pin-policy";
import { usePinEntryStore } from "../store/pin-entry-store";
import { usePinStatusStore } from "../store/pin-status-store";

export type PinGateMode = "loading" | "error" | "set" | "confirm" | "unlock";

export function usePinGate(onUnlocked: () => void) {
  const status = usePinStatusStore();
  const entry = usePinEntryStore();
  const [step, setStep] = useState<"next" | "confirm">("next");
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (status.unlocked) return onUnlocked();
    if (status.loaded) return;
    let live = true;
    getPinStatus().then((res) => {
      if (!live) return;
      if (!res.ok) return setLoadError(sentence(res.error.message));
      setLoadError(null);
      usePinStatusStore.getState().setStatus({ tenantUserId: res.data.tenant_user_id, pinSet: res.data.pin_set, lockedUntil: res.data.locked_until });
    });
    return () => {
      live = false;
    };
  }, [status.unlocked, status.loaded, onUnlocked, attempt]);

  const submitNew = useCallback(async () => {
    const { next, confirm, wipe, clear } = usePinEntryStore.getState();
    if (step === "next") {
      const refusal = pinPolicyRefusal(next);
      if (refusal) {
        clear("next");
        return setMessage(sentence(refusal));
      }
      setMessage(null);
      return setStep("confirm");
    }
    if (confirm !== next) {
      wipe();
      setStep("next");
      return setMessage("The two PINs did not match. Choose your PIN again.");
    }
    setBusy(true);
    const res = await setPin(next);
    wipe();
    setBusy(false);
    setStep("next");
    if (res.ok) usePinStatusStore.getState().unlock();
    else setMessage(sentence(res.error.message));
  }, [step]);

  const submitUnlock = useCallback(async () => {
    const { current, wipe } = usePinEntryStore.getState();
    setBusy(true);
    const res = await verifyPin(current);
    wipe();
    setBusy(false);
    if (!res.ok) return setMessage(sentence(res.error.message));
    if (res.data.ok) return usePinStatusStore.getState().unlock();
    usePinStatusStore.getState().setAttempts(res.data.attempts_left, res.data.locked_until);
    setMessage(res.data.locked_until ? "Too many wrong PINs. Try again after 15 minutes." : `Wrong PIN. ${res.data.attempts_left ?? 0} attempts left.`);
  }, []);

  const mode: PinGateMode = loadError ? "error" : !status.loaded ? "loading" : status.pinSet ? "unlock" : step === "next" ? "set" : "confirm";
  const value = mode === "unlock" ? entry.current : mode === "confirm" ? entry.confirm : entry.next;
  const field = mode === "unlock" ? "current" : mode === "confirm" ? "confirm" : "next";

  return {
    mode,
    value,
    onChange: (v: string) => entry.set(field, v),
    submit: mode === "unlock" ? submitUnlock : submitNew,
    message,
    busy,
    loadError,
    retry: () => {
      setLoadError(null);
      setAttempt((n) => n + 1);
    },
    lockedUntil: status.lockedUntil,
  };
}
