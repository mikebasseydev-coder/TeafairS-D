import "../../global.css";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { usePrefsStore } from "@/features/shell";
import { effectiveTheme } from "@/shared/tokens";
import { ThemeProvider } from "@/shared/ui";

export default function RootLayout() {
  // No membership is known before sign-in (B2), so the role default is standard.
  const theme = effectiveTheme(usePrefsStore((s) => s.theme), null);
  return (
    <SafeAreaProvider>
      <ThemeProvider theme={theme}>
        <StatusBar style={theme === "dark" ? "light" : "dark"} />
        <Stack screenOptions={{ headerShown: false }} />
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
