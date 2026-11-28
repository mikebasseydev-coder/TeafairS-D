import { Redirect } from "expo-router";
import { useSignOut } from "@/features/auth";
import { AccessStateScreen, useAccess } from "@/features/tenant";

export default function AccessRoute() {
  const { ready, route } = useAccess();
  const out = useSignOut();
  if (ready && route !== "use-web") return <Redirect href="/" />;
  return <AccessStateScreen kind="use-web" onSignOut={() => void out.signOut()} signingOut={out.busy} />;
}
