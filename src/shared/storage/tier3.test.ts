import { __clearResetsForTest, registeredResets, runResets } from "./reset-registry";
import { onAppStateChange, registerTier3 } from "./tier3";

beforeEach(() => __clearResetsForTest());

describe("Tier 3 wipes (Spec B §5)", () => {
  it("registers for both reset scopes and wipes on tenant switch and sign-out", async () => {
    const wipe = jest.fn();
    registerTier3("t.a", wipe);
    expect(registeredResets("tenant")).toContain("tier3.t.a");
    expect(registeredResets("session")).toContain("tier3.t.a");
    await runResets("tenant");
    expect(wipe).toHaveBeenCalledTimes(1);
    await runResets("session"); // tenant first, then session
    expect(wipe).toHaveBeenCalledTimes(3);
  });
  it("wipes when the app goes to the background, not for inactive or active", () => {
    const wipe = jest.fn();
    registerTier3("t.b", wipe);
    onAppStateChange("inactive");
    onAppStateChange("active");
    expect(wipe).not.toHaveBeenCalled();
    onAppStateChange("background");
    expect(wipe).toHaveBeenCalled();
  });
  it("uses the narrower background wipe when one is named", () => {
    const wipe = jest.fn();
    const onBackground = jest.fn();
    registerTier3("t.c", wipe, { onBackground });
    onAppStateChange("background");
    expect(onBackground).toHaveBeenCalled();
  });
});
