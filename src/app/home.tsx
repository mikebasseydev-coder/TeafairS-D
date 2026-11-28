import { Redirect, useRouter } from "expo-router";
import { HomeScreen } from "@/features/shell";
import { useAccess, usePinUnlocked } from "@/features/tenant";

export default function HomeRoute() {
  const router = useRouter();
  const { ready, route } = useAccess();
  const unlocked = usePinUnlocked();
  if (ready && (route !== "pin" || !unlocked)) return <Redirect href="/" />;
  return <HomeScreen onChangePin={() => router.push("/pin-change")} />;
}
