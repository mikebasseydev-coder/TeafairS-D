import { View } from "react-native";
import { Banner, Button, Field, Text } from "@/shared/ui";

export type EmailStepProps = {
  email: string;
  onChangeEmail: (email: string) => void;
  onSubmit: () => void;
  busy: boolean;
  inputError: string | null;
  failure: string | null;
};

export function EmailStep({ email, onChangeEmail, onSubmit, busy, inputError, failure }: EmailStepProps) {
  return (
    <View style={{ gap: 16 }} testID="sign-in-email">
      <Text variant="title">Sign in</Text>
      <Text color="muted">We email you a six-digit code. Use the address your team invited.</Text>
      <Field
        label="Email"
        value={email}
        onChangeText={onChangeEmail}
        onSubmitEditing={onSubmit}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        textContentType="emailAddress"
        error={inputError ?? undefined}
        testID="sign-in-email-input"
      />
      {failure ? <Banner tone="danger" title={failure} testID="sign-in-failure" /> : null}
      <Button label="Send code" onPress={onSubmit} busy={busy} testID="sign-in-send" />
    </View>
  );
}
