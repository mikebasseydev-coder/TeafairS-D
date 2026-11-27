// B1 has no sign-in yet (B2): the start screen is a brand moment that leads
// to the primitives gallery.
import { Link } from "expo-router";
import { View } from "react-native";
import { Emblem, Screen, Text } from "@/shared/ui";

export default function Index() {
  return (
    <Screen scroll={false}>
      <View className="flex-1 items-center justify-center" style={{ gap: 16 }}>
        <Emblem size={96} />
        <Text variant="title">Teafair RTM</Text>
        <Link href="/gallery" className="text-base font-semibold text-ink underline">
          Open the primitives gallery
        </Link>
      </View>
    </Screen>
  );
}
