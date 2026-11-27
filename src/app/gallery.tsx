import { useLocalSearchParams } from "expo-router";
import { GalleryScreen } from "@/features/gallery";
import { THEMES, type ThemeName } from "@/shared/tokens";

export default function GalleryRoute() {
  const { theme, insets } = useLocalSearchParams<{ theme?: string; insets?: string }>();
  const initial: ThemeName = (THEMES as readonly string[]).includes(theme ?? "") ? (theme as ThemeName) : "standard";
  return <GalleryScreen key={initial} initialTheme={initial} simulateNotch={insets === "notch"} />;
}
