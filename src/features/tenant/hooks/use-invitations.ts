// Accept or decline one invitation (Spec B §9.3). Online only, a fresh key
// per attempt. Accepting refreshes the session so the token carries the tenant.
import { useCallback, useState } from "react";
import { refreshSession } from "@/features/auth";
import { acceptInvitation, declineInvitation } from "../services/invitations-service";
import { sentence } from "../services/pin-policy";
import { useInvitationStore } from "../store/invitation-store";

export function useInvitations() {
  const { items, status, error } = useInvitationStore();
  const [busyId, setBusyId] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  const run = useCallback(async (id: string, accept: boolean) => {
    setBusyId(id);
    setFailure(null);
    const res = accept ? await acceptInvitation(id) : await declineInvitation(id);
    if (res.ok) {
      useInvitationStore.getState().remove(id);
      if (accept) await refreshSession();
    } else setFailure(sentence(res.error.message));
    setBusyId(null);
    return res.ok;
  }, []);

  return {
    items,
    loading: status === "loading" || status === "idle",
    loadError: error ? sentence(error.message) : null,
    accept: (id: string) => run(id, true),
    decline: (id: string) => run(id, false),
    busyId,
    failure,
  };
}
