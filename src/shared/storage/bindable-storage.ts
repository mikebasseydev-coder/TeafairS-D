// A Zustand `persist` storage that is bound to an MMKV instance only once the
// user (and, for tenant stores, the tenant) is known (Spec B §5). Unbound, it
// reads nothing and writes nothing, so the store lives in memory. Unbinding
// detaches: the namespace's data stays where it is, encrypted.
import type { StateStorage } from "zustand/middleware";

type KeyValue = { getString(key: string): string | undefined; set(key: string, value: string): void; remove(key: string): unknown };

export type BindableStorage = {
  storage: StateStorage;
  bind(store: KeyValue, namespace: string): void;
  unbind(): void;
  boundTo(): string | null;
};

export function createBindableStorage(): BindableStorage {
  let target: KeyValue | null = null;
  let namespace: string | null = null;
  return {
    storage: {
      getItem: (name) => target?.getString(name) ?? null,
      setItem: (name, value) => void target?.set(name, value),
      removeItem: (name) => void target?.remove(name),
    },
    bind(store, ns) {
      target = store;
      namespace = ns;
    },
    unbind() {
      target = null;
      namespace = null;
    },
    boundTo: () => namespace,
  };
}
