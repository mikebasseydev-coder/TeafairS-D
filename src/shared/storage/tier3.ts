// Tier 3 (Spec B §5): secrets held only while they are typed. A Tier 3 store
// registers its wipe once, and it runs on tenant switch and sign-out (through
// the reset registry) and whenever the app leaves the foreground. Wiping on
// submit is the caller's job, success or failure.
//
// A store may name a narrower background wipe. The sign-in code is the case:
// the person leaves the app to read the email, so going to the background
// drops the code typed so far but keeps the step and the address.
import { AppState, type AppStateStatus } from "react-native";
import { registerReset } from "./reset-registry";

type Wipe = () => void;

const wipes = new Map<string, Wipe>();
let subscribed = false;

export function onAppStateChange(state: AppStateStatus): void {
  // "inactive" also fires for iOS system sheets (code autofill), so only a real background wipes
  if (state !== "background") return;
  for (const wipe of wipes.values()) wipe();
}

export function registerTier3(name: string, wipe: Wipe, options: { onBackground?: Wipe } = {}): void {
  wipes.set(name, options.onBackground ?? wipe);
  registerReset("tenant", `tier3.${name}`, wipe);
  registerReset("session", `tier3.${name}`, wipe);
  if (!subscribed) {
    subscribed = true;
    AppState.addEventListener("change", onAppStateChange);
  }
}

export function registeredTier3(): string[] {
  return [...wipes.keys()];
}
