// usePinEntryStore (§5.2.2, G8, Tier 3): the digits while they are typed.
// Never persisted; wiped on submit, on background, on tenant switch and on
// sign-out. It holds buffers only: the rules live in the hooks.
import { create } from "zustand";
import { registerTier3 } from "@/shared/storage/tier3";

export type PinField = "current" | "next" | "confirm";

type PinEntryState = {
  current: string;
  next: string;
  confirm: string;
  set: (field: PinField, value: string) => void;
  clear: (field: PinField) => void;
  wipe: () => void;
};

const empty = { current: "", next: "", confirm: "" };

export const usePinEntryStore = create<PinEntryState>((set) => ({
  ...empty,
  set: (field, value) => set({ [field]: value.replace(/\D/g, "").slice(0, 4) } as Pick<PinEntryState, PinField>),
  clear: (field) => set({ [field]: "" } as Pick<PinEntryState, PinField>),
  wipe: () => set(empty),
}));

registerTier3("tenant.pin-entry", () => usePinEntryStore.getState().wipe());
