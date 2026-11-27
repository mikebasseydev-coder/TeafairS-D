// The theme root: sets the semantic CSS variables for one theme (NativeWind
// `vars`), and gives components that cannot take a class (SVG strokes, the
// moti shimmer, ActivityIndicator) the same resolved colours.
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { View, type ViewProps } from "react-native";
import { vars } from "nativewind";
import { webData } from "./web-data";
import { resolveTheme, themeMetrics, themeVariables, type ResolvedTheme, type ThemeName } from "@/shared/tokens";

type ThemeValue = ResolvedTheme & { metrics: (typeof themeMetrics)[ThemeName] };

const ThemeContext = createContext<ThemeValue | null>(null);

export function useTheme(): ThemeValue {
  const t = useContext(ThemeContext);
  if (!t) throw new Error("useTheme outside <ThemeProvider>");
  return t;
}

export function ThemeProvider({ theme, children, ...rest }: { theme: ThemeName; children: ReactNode } & ViewProps) {
  const value = useMemo<ThemeValue>(() => ({ ...resolveTheme(theme), metrics: themeMetrics[theme] }), [theme]);
  const style = useMemo(() => vars(themeVariables(theme)), [theme]);
  return (
    <ThemeContext.Provider value={value}>
      <View {...rest} style={[style, { flex: 1 }, rest.style]} className="bg-canvas" testID={rest.testID ?? "theme-root"} {...webData({ theme })}>
        {children}
      </View>
    </ThemeContext.Provider>
  );
}
