import { View } from "react-native";
import { Banner, Button, OtpInput, Text } from "@/shared/ui";

export type CodeStepProps = {
  email: string;
  code: string;
  onChangeCode: (code: string) => void;
  onSubmit: () => void;
  onResend: () => void;
  onChangeEmail: () => void;
  secondsToResend: number;
  busy: "idle" | "sending" | "verifying";
  inputError: string | null;
  failure: string | null;
};

export function CodeStep(p: CodeStepProps) {
  return (
    <View style={{ gap: 16 }} testID="sign-in-code">
      <Text variant="title">Enter the code</Text>
      <Text color="muted">We sent a six-digit code to {p.email}.</Text>
      <OtpInput value={p.code} onChange={p.onChangeCode} label="Sign-in code" testID="sign-in-code-input" />
      {p.inputError ? <Banner tone="warning" title={p.inputError} /> : null}
      {p.failure ? <Banner tone="danger" title={p.failure} testID="sign-in-failure" /> : null}
      <Button label="Sign in" onPress={p.onSubmit} busy={p.busy === "verifying"} disabled={p.code.length !== 6} testID="sign-in-verify" />
      <Button
        label={p.secondsToResend > 0 ? `Send a new code in ${p.secondsToResend} s` : "Send a new code"}
        variant="secondary"
        onPress={p.onResend}
        busy={p.busy === "sending"}
        disabled={p.secondsToResend > 0}
        testID="sign-in-resend"
      />
      <Button label="Use another email" variant="secondary" onPress={p.onChangeEmail} testID="sign-in-change-email" />
    </View>
  );
}
