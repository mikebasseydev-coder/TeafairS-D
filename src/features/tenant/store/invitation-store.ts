// useInvitationStore (Spec B §5): the list_my_invitations() result. Memory.
import { create } from "zustand";
import type { AppError } from "@/shared/network/errors";
import { registerReset } from "@/shared/storage/reset-registry";
import type { Invitation } from "../types";

type Status = "idle" | "loading" | "ready" | "error";

type InvitationState = {
  status: Status;
  items: Invitation[];
  error: AppError | null;
  loading: () => void;
  loaded: (items: Invitation[]) => void;
  failed: (error: AppError) => void;
  remove: (tenantUserId: string) => void;
};

const empty = { status: "idle" as Status, items: [] as Invitation[], error: null };

export const useInvitationStore = create<InvitationState>((set) => ({
  ...empty,
  loading: () => set({ status: "loading", error: null }),
  loaded: (items) => set({ status: "ready", items, error: null }),
  failed: (error) => set({ status: "error", error }),
  remove: (id) => set((s) => ({ items: s.items.filter((i) => i.tenant_user_id !== id) })),
}));

registerReset("session", "tenant.invitations", () => useInvitationStore.setState(empty));
