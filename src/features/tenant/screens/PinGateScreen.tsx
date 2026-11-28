// The PIN gate (Spec B §9.5). The route decides where "unlocked" leads.
import { Banner, Screen, SkeletonRegion, Skeleton } from "@/shared/ui";
import { PinPrompt } from "../components/PinPrompt";
import { usePinGate } from "../hooks/use-pin-gate";

const COPY = {
  set: { title: "Choose a PIN", hint: "Four digits. Not one digit repeated, and not a run such as 1234.", label: "New PIN", submit: "Continue" },
  confirm: { title: "Confirm your PIN", hint: "Enter the same four digits again.", label: "Confirm PIN", submit: "Set PIN" },
  unlock: { title: "Enter your PIN", hint: "Your PIN for this team.", label: "PIN", submit: "Unlock" },
} as const;

export function PinGateScreen({ onUnlocked }: { onUnlocked: () => void }) {
  const g = usePinGate(onUnlocked);
  if (g.mode === "loading")
    return (
      <Screen testID="pin-gate">
        <SkeletonRegion>
          <Skeleton height={240} />
        </SkeletonRegion>
      </Screen>
    );
  if (g.mode === "error")
    return (
      <Screen testID="pin-gate">
        <Banner tone="danger" title={g.loadError ?? "Could not load your PIN."} action={{ label: "Try again", onPress: () => void g.retry() }} />
      </Screen>
    );
  const c = COPY[g.mode];
  return (
    <Screen testID="pin-gate">
      <PinPrompt
        testID={`pin-${g.mode}`}
        title={c.title}
        hint={c.hint}
        label={c.label}
        value={g.value}
        onChange={g.onChange}
        onSubmit={() => void g.submit()}
        submitLabel={c.submit}
        busy={g.busy}
        message={g.message}
      />
    </Screen>
  );
}
