import { decodeClaims } from "@/features/auth";
import { decideAccess } from "./access";
import { pinPolicyRefusal } from "./pin-policy";

describe("pinPolicyRefusal mirrors the database rule", () => {
  it.each(["7777", "1234", "6543", "0123", "9876", "123", "12345", "12a4"])("refuses %s", (pin) => {
    expect(pinPolicyRefusal(pin)).not.toBeNull();
  });
  it.each(["2580", "1357", "1123", "9870", "0001"])("allows %s", (pin) => {
    expect(pinPolicyRefusal(pin)).toBeNull();
  });
  it("uses the database's own copy", () => {
    expect(pinPolicyRefusal("7777")).toBe("choose a PIN that is not one digit repeated");
    expect(pinPolicyRefusal("1234")).toBe("choose a PIN that is not a run of digits");
  });
});

describe("decideAccess (Spec B §9.3)", () => {
  const none = decodeClaims(null);
  const base = { signedIn: true, claims: none, invitationCount: 0, hasAgentMembership: false };
  it("signed out → sign-in", () => expect(decideAccess({ ...base, signedIn: false })).toBe("sign-in"));
  it("an active tenant → the PIN gate, even with invitations", () =>
    expect(decideAccess({ ...base, claims: { ...none, activeTenantId: "t" }, invitationCount: 2 })).toBe("pin"));
  it("no tenant but invitations → onboarding", () => expect(decideAccess({ ...base, invitationCount: 1 })).toBe("onboarding"));
  it("no tenant, no invitation, an agent membership → agent", () => expect(decideAccess({ ...base, hasAgentMembership: true })).toBe("agent"));
  it("only a platform role → TeafairWeb", () =>
    expect(decideAccess({ ...base, claims: { ...none, platformRole: "MONVELO_OPERATOR" } })).toBe("use-web"));
  it("nothing → no access yet", () => expect(decideAccess(base)).toBe("no-access"));
});
