import { Redirect, useRouter } from "expo-router";
import { PinChangeScreen, useAccess, usePinUnlocked } from "@/features/tenant";

export default function PinChangeRoute() {
  const router = useRouter();
  const { ready, route } = useAccess();
  const unlocked = usePinUnlocked();
  if (ready && (route !== "pin" || !unlocked)) return <Redirect href="/" />;
  return <PinChangeScreen onDone={() => router.replace("/home")} />;
}
