// Change the PIN (Spec B §9.5): a fresh key on every attempt; a wrong current
// PIN is an answer ({changed:false, attempts_remaining}), not an error.
import { useCallback, useState } from "react";
import { changePin } from "../services/pin-service";
import { pinPolicyRefusal, sentence } from "../services/pin-policy";
import { usePinEntryStore } from "../store/pin-entry-store";
import { usePinStatusStore } from "../store/pin-status-store";

export type PinChangeStep = "current" | "next" | "confirm" | "done";

export function usePinChange() {
  const entry = usePinEntryStore();
  const [step, setStep] = useState<PinChangeStep>("current");
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = useCallback(async () => {
    const s = usePinEntryStore.getState();
    if (step === "current") {
      if (s.current.length !== 4) return;
      setMessage(null);
      return setStep("next");
    }
    if (step === "next") {
      const refusal = pinPolicyRefusal(s.next);
      if (refusal) {
        s.clear("next");
        return setMessage(sentence(refusal));
      }
      setMessage(null);
      return setStep("confirm");
    }
    if (s.confirm !== s.next) {
      s.clear("next");
      s.clear("confirm");
      setStep("next");
      return setMessage("The two PINs did not match. Choose your new PIN again.");
    }
    setBusy(true);
    const res = await changePin(s.current, s.next);
    s.wipe();
    setBusy(false);
    if (!res.ok) {
      setStep("current");
      return setMessage(sentence(res.error.message));
    }
    if (res.data.changed) {
      setMessage(null);
      return setStep("done");
    }
    usePinStatusStore.getState().setAttempts(res.data.attempts_remaining, res.data.locked_until);
    setStep("current");
    setMessage(
      res.data.locked_until
        ? "Too many wrong PINs. Try again after 15 minutes."
        : `Your current PIN was wrong. ${res.data.attempts_remaining} attempts left.`,
    );
  }, [step]);

  const field = step === "done" ? "current" : step;
  return {
    step,
    value: step === "done" ? "" : entry[field],
    onChange: (v: string) => entry.set(field, v),
    submit,
    message,
    busy,
    restart: () => {
      usePinEntryStore.getState().wipe();
      setMessage(null);
      setStep("current");
    },
  };
}
