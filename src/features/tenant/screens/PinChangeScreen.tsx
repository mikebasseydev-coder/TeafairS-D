// Change the PIN (Spec B §9.5). A forgotten PIN has no reset yet: ask the ZSM.
import { View } from "react-native";
import { Banner, Button, Screen } from "@/shared/ui";
import { PinPrompt } from "../components/PinPrompt";
import { usePinChange } from "../hooks/use-pin-change";

const COPY = {
  current: { title: "Change your PIN", hint: "Enter your current PIN. If you have forgotten it, ask your ZSM.", label: "Current PIN", submit: "Continue" },
  next: { title: "Choose a new PIN", hint: "Four digits. Not one digit repeated, and not a run such as 1234.", label: "New PIN", submit: "Continue" },
  confirm: { title: "Confirm your new PIN", hint: "Enter the same four digits again.", label: "Confirm PIN", submit: "Change PIN" },
} as const;

export function PinChangeScreen({ onDone }: { onDone: () => void }) {
  const c = usePinChange();
  if (c.step === "done")
    return (
      <Screen testID="pin-change">
        <View style={{ gap: 16, width: "100%", maxWidth: 440, alignSelf: "center" }}>
          <Banner tone="success" title="Your PIN is changed." testID="pin-changed" />
          <Button label="Done" onPress={onDone} testID="pin-change-done" />
        </View>
      </Screen>
    );
  const copy = COPY[c.step];
  return (
    <Screen testID="pin-change">
      <PinPrompt
        testID={`pin-change-${c.step}`}
        title={copy.title}
        hint={copy.hint}
        label={copy.label}
        value={c.value}
        onChange={c.onChange}
        onSubmit={() => void c.submit()}
        submitLabel={copy.submit}
        busy={c.busy}
        message={c.message}
      />
      <View style={{ width: "100%", maxWidth: 440, alignSelf: "center", marginTop: 12 }}>
        <Button label="Cancel" variant="secondary" onPress={onDone} testID="pin-change-cancel" />
      </View>
    </Screen>
  );
}
