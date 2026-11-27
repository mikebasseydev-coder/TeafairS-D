// The B1 primitives gallery (Spec B §11): every shared/ui primitive in the
// theme chosen here, at phone and tablet widths. It is a verification surface,
// not a product screen, and imports nothing but `shared`.
import { useState, type ReactNode } from "react";
import { Pressable, View } from "react-native";
import { SafeAreaInsetsContext, useSafeAreaInsets } from "react-native-safe-area-context";
import {
  Badge,
  Banner,
  BentoGrid,
  BentoTile,
  Button,
  Card,
  Emblem,
  EmptyState,
  Field,
  ListRow,
  OtpInput,
  PinPad,
  Screen,
  Sheet,
  Skeleton,
  SkeletonList,
  SkeletonRegion,
  SkeletonText,
  SyncIndicator,
  Text,
  ThemeProvider,
  webData,
} from "@/shared/ui";
import { THEMES, TONES, type SemanticToken, type ThemeName } from "@/shared/tokens";
import { queueLabel, queueTone, type QueueStatus } from "@/shared/network/queue/queue-tone";

/** Literal classes, so NativeWind generates each one. */
const SWATCH: Partial<Record<SemanticToken, string>> = {
  canvas: "bg-canvas",
  surface: "bg-surface",
  ink: "bg-ink",
  "ink-muted": "bg-ink-muted",
  hairline: "bg-hairline",
  control: "bg-control",
  focus: "bg-focus",
  action: "bg-action",
  "action-strong": "bg-action-strong",
  skeleton: "bg-skeleton",
};

const TONE_LABEL = {
  neutral: "Closed",
  brand: "Funded",
  success: "Repaid",
  warning: "Held",
  danger: "Refund due",
  info: "Offered",
  pending: "Awaiting approval",
} as const;

const ROWS = [
  { title: "Mama Nkechi Stores", subtitle: "Allen Avenue, Ikeja", meta: "₦48,500.00" },
  { title: "Opebi Corner Shop", subtitle: "Opebi Road", meta: "₦12,000.00" },
  { title: "Adeniyi Provisions", subtitle: "Toyin Street", meta: "₦7,250.00" },
  { title: "Bola Mini Mart", subtitle: "Awolowo Way", meta: "₦31,900.00" },
  { title: "Kemi & Sons", subtitle: "Obafemi Awolowo Way", meta: "₦5,000.00" },
];

function Section({ title, children, testID }: { title: string; children: ReactNode; testID?: string }) {
  return (
    <View style={{ gap: 12 }} testID={testID}>
      <Text variant="heading" accessibilityRole="header">
        {title}
      </Text>
      {children}
    </View>
  );
}

function Thrower(): ReactNode {
  throw new Error("a tile's render failed");
}

function SafeAreaProbe() {
  const i = useSafeAreaInsets();
  return <View testID="safe-area-probe" {...webData({ top: String(i.top), bottom: String(i.bottom) })} />;
}

function Gallery({ theme, onTheme }: { theme: ThemeName; onTheme: (t: ThemeName) => void }) {
  const [pin, setPin] = useState("");
  const [otp, setOtp] = useState("");
  const [sheet, setSheet] = useState(false);
  const [retries, setRetries] = useState(0);
  return (
    <Screen testID="gallery">
      <SafeAreaProbe />
      <View className="flex-row items-center" style={{ gap: 8 }} testID="gallery-header">
        <Emblem size={48} />
        <View className="flex-1">
          <Text variant="title" accessibilityRole="header">
            Teafair RTM
          </Text>
          <Text variant="label" color="muted">
            B1 primitives gallery
          </Text>
        </View>
      </View>

      <Section title="Theme">
        <View className="flex-row flex-wrap" style={{ gap: 8 }}>
          {THEMES.map((t) => (
            <Pressable
              key={t}
              testID={`theme-${t}`}
              accessibilityRole="button"
              accessibilityState={{ selected: t === theme }}
              onPress={() => onTheme(t)}
              className={`rounded-lg px-4 py-3 ${t === theme ? "bg-action-strong" : "border border-control bg-surface"}`}
            >
              <Text variant="label" color={t === theme ? "on-action-strong" : "ink"}>
                {t}
              </Text>
            </Pressable>
          ))}
        </View>
        <View className="flex-row flex-wrap" style={{ gap: 8 }}>
          {(Object.keys(SWATCH) as SemanticToken[]).map((k) => (
            <View key={k} style={{ gap: 4, width: 76 }}>
              <View testID={`swatch-${k}`} className={`h-10 rounded-lg border border-control ${SWATCH[k]}`} />
              <Text variant="caption" numberOfLines={1}>
                {k}
              </Text>
            </View>
          ))}
        </View>
      </Section>

      <Section title="Type">
        <Text variant="display">Display 32</Text>
        <Text variant="title">Title 24</Text>
        <Text variant="heading">Heading 20</Text>
        <Text variant="body">Body 16: requests close 15:00 Lagos.</Text>
        <Text variant="label">Label 14 semibold</Text>
        <Text variant="caption" color="muted">
          Caption 12, muted
        </Text>
        <Text variant="heading" tabular>
          ₦1,000,000.00
        </Text>
      </Section>

      <Section title="Buttons">
        <View style={{ gap: 8 }}>
          <Button label="Primary action" testID="button-primary" />
          <Button label="Accent action" variant="accent" />
          <Button label="Secondary action" variant="secondary" />
          <Button label="Sending" busy />
          <Button label="Disabled" disabled />
        </View>
      </Section>

      <Section title="Status: tone, words and icon" testID="badges">
        <View className="flex-row flex-wrap" style={{ gap: 8 }}>
          {TONES.map((tone) => (
            <Badge key={tone} tone={tone} label={TONE_LABEL[tone]} testID={`badge-${tone}`} />
          ))}
        </View>
        <View className="flex-row flex-wrap" style={{ gap: 8 }}>
          {(Object.keys(queueTone) as QueueStatus[]).map((s) => (
            <Badge key={s} tone={queueTone[s]} label={queueLabel[s]} />
          ))}
        </View>
        <View className="flex-row flex-wrap" style={{ gap: 8 }}>
          <SyncIndicator state={{ kind: "online" }} />
          <SyncIndicator state={{ kind: "syncing" }} />
          <SyncIndicator state={{ kind: "offline", since: "10:42" }} />
          <SyncIndicator state={{ kind: "unavailable" }} />
        </View>
      </Section>

      <Section title="Banners">
        <Banner tone="danger" title="the shop owner has no verified email" message="Ask the owner to verify their sign-in email first." />
        <Banner tone="warning" title="Requests close 15:00 Lagos" message="A request raised now is for tomorrow's supply." />
        <Banner tone="info" title="Ask the owner to read the code from their email" />
        <Banner tone="success" title="Repayment confirmed" />
      </Section>

      <Section title="Inputs">
        <Field label="Business name" placeholder="As registered" />
        <Field label="Reason" error="give a reason of 10 to 500 characters" defaultValue="too short" />
        <OtpInput label="Owner's code" value={otp} onChange={setOtp} />
        <PinPad label="Enter your PIN" value={pin} onChange={setPin} />
      </Section>

      <Section title="Lists and skeletons">
        <Card>
          <Text variant="label" color="muted">
            Loading (pulse, 5 rows)
          </Text>
          <View className="-mx-4">
            <SkeletonList rows={5} testID="list-skeleton" />
          </View>
        </Card>
        <Card>
          <Text variant="label" color="muted">
            Loaded
          </Text>
          <View className="-mx-4" testID="list-loaded">
            {ROWS.map((r, i) => (
              <ListRow key={r.title} {...r} badge={i === 0 ? { tone: "warning", label: "Held" } : undefined} />
            ))}
          </View>
        </Card>
        <Card testID="shimmer-hero">
          <Text variant="label" color="muted">
            Detail header (shimmer, the one per screen)
          </Text>
          <SkeletonRegion>
            <View style={{ gap: 12 }}>
              <Skeleton variant="shimmer" height={28} width="60%" />
              <SkeletonText lines={2} variant="shimmer" />
            </View>
          </SkeletonRegion>
        </Card>
      </Section>

      <Section title="Bento">
        <BentoGrid testID="bento">
          <BentoTile key="pipeline" title="Pipeline" span="2x2" state={{ status: "ready" }} testID="tile-pipeline">
            <Text variant="display" tabular>
              24
            </Text>
            <Text variant="body" color="muted">
              open financings in your scope
            </Text>
            <Badge tone="warning" label="3 holds awaiting you" />
          </BentoTile>
          <BentoTile key="pledged" title="Pledged" state={{ status: "ready" }} testID="tile-pledged">
            <SyncIndicator state={{ kind: "unavailable" }} />
          </BentoTile>
          <BentoTile key="holds" title="Holds" state={{ status: "loading", hasData: false }} testID="tile-loading" />
          <BentoTile
            key="recruits"
            title="My recruits"
            span="2x1"
            state={{ status: "error", message: `Network unavailable (${retries} retries)` }}
            onRetry={() => setRetries((n) => n + 1)}
            testID="tile-error"
          />
          <BentoTile key="pairings" title="Pairings" state={{ status: "ready" }} testID="tile-throws">
            <Thrower />
          </BentoTile>
          <BentoTile key="shops" title="Shops" state={{ status: "ready" }} testID="tile-shops">
            <Text variant="title" tabular>
              41
            </Text>
          </BentoTile>
          <BentoTile key="nominations" title="Nominations" state={{ status: "empty", message: "No open nominations" }} testID="tile-empty" />
        </BentoGrid>
      </Section>

      <Section title="Brand moments">
        <View className="flex-row flex-wrap items-end" style={{ gap: 8 }} testID="emblems">
          {([24, 32, 48, 64, 96] as const).map((s) => (
            <Emblem key={s} size={s} testID={`emblem-${s}`} />
          ))}
        </View>
        <Card>
          <EmptyState emblem title="No shops yet" message="Shops you enrol appear here." action={{ label: "Open the sheet", onPress: () => setSheet(true) }} />
        </Card>
      </Section>

      <Sheet visible={sheet} onClose={() => setSheet(false)} title="A sheet">
        <Text variant="body">Sheets sit over the scrim, the one translucent layer.</Text>
      </Sheet>
    </Screen>
  );
}

const NOTCH = { top: 47, right: 0, bottom: 34, left: 0 };

/** `theme` and `insets` come from the route, so a test can open any state directly. */
export function GalleryScreen({ initialTheme, simulateNotch }: { initialTheme: ThemeName; simulateNotch: boolean }) {
  const [theme, setTheme] = useState<ThemeName>(initialTheme);
  const body = (
    <ThemeProvider theme={theme} testID="gallery-theme">
      <Gallery theme={theme} onTheme={setTheme} />
    </ThemeProvider>
  );
  return simulateNotch ? <SafeAreaInsetsContext.Provider value={NOTCH}>{body}</SafeAreaInsetsContext.Provider> : body;
}
