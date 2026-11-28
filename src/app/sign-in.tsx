import { Redirect } from "expo-router";
import { SignInScreen, useSessionStatus } from "@/features/auth";

export default function SignInRoute() {
  const status = useSessionStatus();
  if (status === "signedIn") return <Redirect href="/" />;
  return <SignInScreen />;
}
