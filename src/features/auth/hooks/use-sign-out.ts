import { useCallback, useState } from "react";
import { signOut } from "../services/auth-service";

export function useSignOut() {
  const [busy, setBusy] = useState(false);
  const run = useCallback(async () => {
    setBusy(true);
    try {
      await signOut();
    } finally {
      setBusy(false);
    }
  }, []);
  return { signOut: run, busy };
}
