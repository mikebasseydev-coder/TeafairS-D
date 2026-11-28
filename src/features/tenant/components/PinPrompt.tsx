import { View } from "react-native";
import { Banner, Button, PinPad, Text } from "@/shared/ui";

export type PinPromptProps = {
  title: string;
  hint: string;
  label: string;
  value: string;
  onChange: (v: string) => void;
  onSubmit: () => void;
  submitLabel: string;
  busy: boolean;
  message: string | null;
  messageTone?: "danger" | "warning";
  testID?: string;
};

export function PinPrompt(p: PinPromptProps) {
  return (
    <View style={{ gap: 16, width: "100%", maxWidth: 440, alignSelf: "center" }} testID={p.testID}>
      <Text variant="title">{p.title}</Text>
      <Text color="muted">{p.hint}</Text>
      <PinPad value={p.value} onChange={p.onChange} label={p.label} testID="pin-pad" />
      {p.message ? <Banner tone={p.messageTone ?? "danger"} title={p.message} testID="pin-message" /> : null}
      <Button label={p.submitLabel} onPress={p.onSubmit} busy={p.busy} disabled={p.value.length !== 4} testID="pin-submit" />
    </View>
  );
}
