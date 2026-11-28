import { Redirect, useRouter } from "expo-router";
import { useCallback } from "react";
import { PinGateScreen, useAccess } from "@/features/tenant";

export default function PinRoute() {
  const router = useRouter();
  const { ready, route } = useAccess();
  const onUnlocked = useCallback(() => router.replace("/home"), [router]);
  if (ready && route !== "pin") return <Redirect href="/" />;
  return <PinGateScreen onUnlocked={onUnlocked} />;
}
