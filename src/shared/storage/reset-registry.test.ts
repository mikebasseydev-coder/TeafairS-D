import { __clearResetsForTest, registerReset, registeredResets, runResets } from "./reset-registry";

beforeEach(() => __clearResetsForTest());

describe("reset registry (Spec B §5)", () => {
  it("a tenant reset runs only tenant resets", async () => {
    const ran: string[] = [];
    registerReset("tenant", "stock", () => void ran.push("stock"));
    registerReset("session", "auth", () => void ran.push("auth"));
    await runResets("tenant");
    expect(ran).toEqual(["stock"]);
  });
  it("a session reset runs tenant first, then session", async () => {
    const ran: string[] = [];
    registerReset("session", "auth", () => void ran.push("auth"));
    registerReset("tenant", "chat", async () => void ran.push("chat"));
    await runResets("session");
    expect(ran).toEqual(["chat", "auth"]);
  });
  it("one failing reset does not stop the others, and the failure surfaces", async () => {
    const ran: string[] = [];
    registerReset("tenant", "bad", () => {
      throw new Error("x");
    });
    registerReset("tenant", "good", () => void ran.push("good"));
    await expect(runResets("tenant")).rejects.toThrow("1 reset(s) failed");
    expect(ran).toEqual(["good"]);
  });
  it("re-registering a name replaces it", () => {
    registerReset("tenant", "a", () => {});
    registerReset("tenant", "a", () => {});
    expect(registeredResets("tenant")).toEqual(["a"]);
  });
});
