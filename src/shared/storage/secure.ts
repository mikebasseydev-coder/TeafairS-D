// Tier 1 (Spec B §5): the Supabase session and the MMKV encryption key, only
// in expo-secure-store. SecureStore values must stay small, so long values are
// chunked. On web (the Playwright target only) values stay in memory.
import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import * as Crypto from "expo-crypto";

const CHUNK = 1800;
const KEY_OK = /^[A-Za-z0-9._-]+$/;

const memory = new Map<string, string>();
const isWeb = Platform.OS === "web";

function check(key: string) {
  if (!KEY_OK.test(key)) throw new Error("secure storage keys are [A-Za-z0-9._-]");
}

async function rawGet(key: string): Promise<string | null> {
  return isWeb ? (memory.get(key) ?? null) : SecureStore.getItemAsync(key);
}
async function rawSet(key: string, value: string): Promise<void> {
  if (isWeb) memory.set(key, value);
  else await SecureStore.setItemAsync(key, value, { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY });
}
async function rawDelete(key: string): Promise<void> {
  if (isWeb) memory.delete(key);
  else await SecureStore.deleteItemAsync(key);
}

export async function secureGet(key: string): Promise<string | null> {
  check(key);
  const count = await rawGet(`${key}.n`);
  if (count === null) return null;
  const parts: string[] = [];
  for (let i = 0; i < Number(count); i++) {
    const p = await rawGet(`${key}.${i}`);
    if (p === null) return null;
    parts.push(p);
  }
  return parts.join("");
}

export async function secureRemove(key: string): Promise<void> {
  check(key);
  const count = await rawGet(`${key}.n`);
  for (let i = 0; i < Number(count ?? 0); i++) await rawDelete(`${key}.${i}`);
  await rawDelete(`${key}.n`);
}

export async function secureSet(key: string, value: string): Promise<void> {
  check(key);
  await secureRemove(key);
  const n = Math.max(1, Math.ceil(value.length / CHUNK));
  for (let i = 0; i < n; i++) await rawSet(`${key}.${i}`, value.slice(i * CHUNK, (i + 1) * CHUNK));
  await rawSet(`${key}.n`, String(n));
}

/** supabase-js `auth.storage`: the session lives in Tier 1 and nowhere else. */
export const secureAuthStorage = {
  getItem: (key: string) => secureGet(sanitise(key)),
  setItem: (key: string, value: string) => secureSet(sanitise(key), value),
  removeItem: (key: string) => secureRemove(sanitise(key)),
};

function sanitise(key: string): string {
  return key.replace(/[^A-Za-z0-9._-]/g, "_");
}

/** The MMKV encryption key for one user (Tier 1), made on first use. */
export async function mmkvKeyFor(userId: string): Promise<string> {
  const name = `mmkv-key.${sanitise(userId)}`;
  const existing = await secureGet(name);
  if (existing) return existing;
  const bytes = await Crypto.getRandomBytesAsync(16);
  // MMKV takes an encryption key of up to 16 bytes
  const key = Array.from(bytes, (b) => (b % 36).toString(36)).join("");
  await secureSet(name, key);
  return key;
}
