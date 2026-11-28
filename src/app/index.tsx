// The entry: Spec B §9.3 decides the destination; this route only redirects.
import { Redirect } from "expo-router";
import { View } from "react-native";
import { useAccess, type AccessRoute } from "@/features/tenant";
import { Emblem, Screen } from "@/shared/ui";

const HREF: Record<AccessRoute, string> = {
  "sign-in": "/sign-in",
  pin: "/pin",
  onboarding: "/onboarding",
  agent: "/agent",
  "use-web": "/use-web",
  "no-access": "/no-access",
};

export default function Index() {
  const { ready, route } = useAccess();
  if (ready) return <Redirect href={HREF[route]} />;
  return (
    <Screen scroll={false} testID="splash">
      <View className="flex-1 items-center justify-center">
        <Emblem size={96} />
      </View>
    </Screen>
  );
}
