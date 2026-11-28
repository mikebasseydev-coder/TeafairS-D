import { Redirect } from "expo-router";
import { AgentHomeScreen } from "@/features/shell";
import { useAccess } from "@/features/tenant";

export default function AgentRoute() {
  const { ready, route } = useAccess();
  if (ready && route !== "agent") return <Redirect href="/" />;
  return <AgentHomeScreen />;
}
