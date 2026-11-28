// Tier 2 (Spec B §5): one encrypted MMKV instance per `${userId}:${tenantId}`
// and a user-level instance `${userId}`, the key held in Tier 1. Never for
// tokens, PINs, OTPs, codes, checkout URLs, buyer contacts or balances.
import { Platform } from "react-native";
import { createMMKV } from "react-native-mmkv";
import type { StateStorage } from "zustand/middleware";
import { mmkvKeyFor } from "./secure";

type Store = ReturnType<typeof createMMKV>;
const open = new Map<string, Store>();

const safe = (s: string) => s.replace(/[^A-Za-z0-9_-]/g, "_");

export function namespaceId(userId: string, tenantId?: string | null): string {
  return tenantId ? `u-${safe(userId)}.t-${safe(tenantId)}` : `u-${safe(userId)}`;
}

async function openNamespace(id: string, userId: string): Promise<Store> {
  const cached = open.get(id);
  if (cached) return cached;
  // MMKV refuses an encryption key on web, which is only the Playwright target
  // (Spec B §11): there it is localStorage, and native storage is proven on a device.
  const store = Platform.OS === "web" ? createMMKV({ id }) : createMMKV({ id, encryptionKey: await mmkvKeyFor(userId) });
  open.set(id, store);
  return store;
}

/** The user-level instance: things above tenants (the theme choice, the last active tenant hint). */
export function openUserStore(userId: string): Promise<Store> {
  return openNamespace(namespaceId(userId), userId);
}

/** The tenant instance: the offline queue, Needs attention, the read cache, filters. */
export function openTenantStore(userId: string, tenantId: string): Promise<Store> {
  return openNamespace(namespaceId(userId, tenantId), userId);
}

/** A Zustand `persist` storage over one open instance. */
export function mmkvStateStorage(store: Store): StateStorage {
  return {
    getItem: (name) => store.getString(name) ?? null,
    setItem: (name, value) => store.set(name, value),
    removeItem: (name) => void store.remove(name),
  };
}

/** Closes the handles (the files stay, encrypted, Spec B §5 sign-out). */
export function forgetOpenStores(): void {
  open.clear();
}
