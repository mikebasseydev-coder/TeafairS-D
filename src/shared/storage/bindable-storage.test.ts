import { createBindableStorage } from "./bindable-storage";

const kv = () => {
  const m = new Map<string, string>();
  return { m, getString: (k: string) => m.get(k), set: (k: string, v: string) => void m.set(k, v), remove: (k: string) => m.delete(k) };
};

describe("bindable storage (Spec B §5)", () => {
  it("reads and writes nothing until bound", async () => {
    const b = createBindableStorage();
    await b.storage.setItem("x", "1");
    expect(await b.storage.getItem("x")).toBeNull();
    expect(b.boundTo()).toBeNull();
  });
  it("writes to the bound namespace, and unbinding detaches without deleting", async () => {
    const b = createBindableStorage();
    const a = kv();
    b.bind(a, "u-1");
    await b.storage.setItem("x", "1");
    expect(a.m.get("x")).toBe("1");
    b.unbind();
    await b.storage.setItem("x", "2");
    expect(a.m.get("x")).toBe("1");
    expect(await b.storage.getItem("x")).toBeNull();
  });
  it("a second user's namespace never sees the first one's values", async () => {
    const b = createBindableStorage();
    const one = kv();
    const two = kv();
    b.bind(one, "u-1");
    await b.storage.setItem("theme", "dark");
    b.unbind();
    b.bind(two, "u-2");
    expect(await b.storage.getItem("theme")).toBeNull();
  });
});
