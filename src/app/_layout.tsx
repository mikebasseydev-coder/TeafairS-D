import "../../global.css";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { useAuthBootstrap } from "@/features/auth";
import { usePrefsBinding, useThemeChoice } from "@/features/shell";
import { useTenantBinding } from "@/features/tenant";
import { ThemeProvider } from "@/shared/ui";

export default function RootLayout() {
  useAuthBootstrap();
  useTenantBinding();
  usePrefsBinding();
  // the saved choice, else the active role's default (Spec B §4.2)
  const { theme } = useThemeChoice();
  return (
    <SafeAreaProvider>
      <ThemeProvider theme={theme}>
        <StatusBar style={theme === "dark" ? "light" : "dark"} />
        <Stack screenOptions={{ headerShown: false }} />
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
