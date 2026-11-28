// Sign-in is one of the few brand moments (Spec B §4.1): the emblem shows here.
import { View } from "react-native";
import { Emblem, Screen } from "@/shared/ui";
import { CodeStep } from "../components/CodeStep";
import { EmailStep } from "../components/EmailStep";
import { useSignIn } from "../hooks/use-sign-in";

export function SignInScreen() {
  const s = useSignIn();
  return (
    <Screen testID="sign-in">
      <View style={{ gap: 24, width: "100%", maxWidth: 440, alignSelf: "center", paddingTop: 32 }}>
        <Emblem size={64} />
        {s.step === "email" ? (
          <EmailStep
            email={s.email}
            onChangeEmail={s.setEmail}
            onSubmit={() => void s.send(s.email)}
            busy={s.busy === "sending"}
            inputError={s.inputError}
            failure={s.failure?.message ?? null}
          />
        ) : (
          <CodeStep
            email={s.email}
            code={s.code}
            onChangeCode={s.setCode}
            onSubmit={() => void s.verify()}
            onResend={() => void s.resend()}
            onChangeEmail={s.backToEmail}
            secondsToResend={s.secondsToResend}
            busy={s.busy}
            inputError={s.inputError}
            failure={s.failure?.message ?? null}
          />
        )}
      </View>
    </Screen>
  );
}
