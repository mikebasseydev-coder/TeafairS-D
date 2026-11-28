import { Redirect } from "expo-router";
import { useSignOut } from "@/features/auth";
import { AccessStateScreen, useAccess } from "@/features/tenant";

export default function AccessRoute() {
  const { ready, route } = useAccess();
  const out = useSignOut();
  if (ready && route !== "no-access") return <Redirect href="/" />;
  return <AccessStateScreen kind="no-access" onSignOut={() => void out.signOut()} signingOut={out.busy} />;
}
