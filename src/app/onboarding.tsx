import { Redirect } from "expo-router";
import { OnboardingScreen, useAccess } from "@/features/tenant";

export default function OnboardingRoute() {
  const { ready, route } = useAccess();
  if (ready && route !== "onboarding") return <Redirect href="/" />;
  return <OnboardingScreen />;
}
