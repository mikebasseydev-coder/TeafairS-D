import { runResets } from "@/shared/storage/reset-registry";
import { prefsStorage, usePrefsStore } from "./prefs-store";

const kv = () => {
  const m = new Map<string, string>();
  return { m, getString: (k: string) => m.get(k), set: (k: string, v: string) => void m.set(k, v), remove: (k: string) => m.delete(k) };
};

describe("usePrefsStore at the user level (Spec B §4.2, §5)", () => {
  it("a choice is saved in the user's namespace, survives sign-out, and returns at the next sign-in", async () => {
    const ada = kv();
    prefsStorage.bind(ada, "u-ada");
    await usePrefsStore.persist.rehydrate();
    usePrefsStore.getState().setTheme("dark");
    expect(JSON.parse(ada.m.get("shell.prefs")!).state.theme).toBe("dark");

    await runResets("session");
    expect(usePrefsStore.getState().theme).toBeNull();
    expect(prefsStorage.boundTo()).toBeNull();
    expect(JSON.parse(ada.m.get("shell.prefs")!).state.theme).toBe("dark");

    prefsStorage.bind(ada, "u-ada");
    await usePrefsStore.persist.rehydrate();
    expect(usePrefsStore.getState().theme).toBe("dark");
  });
  it("another user starts at the role default", async () => {
    await runResets("session");
    prefsStorage.bind(kv(), "u-bo");
    await usePrefsStore.persist.rehydrate();
    expect(usePrefsStore.getState().theme).toBeNull();
  });
});
