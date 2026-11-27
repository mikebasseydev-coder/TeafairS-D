// Cached or offline data is shown, not blocked; the indicator says which
// (Spec B §4.3).
import type { SemanticTone } from "@/shared/tokens";
import { Badge } from "./Badge";

export type SyncState = { kind: "online" } | { kind: "syncing" } | { kind: "offline"; since?: string } | { kind: "unavailable" };

export function syncLabel(s: SyncState): { tone: SemanticTone; label: string } {
  switch (s.kind) {
    case "online":
      return { tone: "success", label: "Up to date" };
    case "syncing":
      return { tone: "pending", label: "Syncing" };
    case "offline":
      return { tone: "warning", label: s.since ? `Offline, showing data from ${s.since}` : "Offline" };
    case "unavailable":
      // financial figures are never cached (Spec B §5)
      return { tone: "neutral", label: "Unavailable offline" };
  }
}

export function SyncIndicator({ state, testID }: { state: SyncState; testID?: string }) {
  const { tone, label } = syncLabel(state);
  return <Badge tone={tone} label={label} testID={testID} />;
}
