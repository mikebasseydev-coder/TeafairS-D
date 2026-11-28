// Spec B §5: importing every barrel registers every store with state.
import { registeredResets } from "@/shared/storage/reset-registry";
import "@/features/auth";
import "@/features/tenant";
import "@/features/shell";

describe("the reset registry knows every B2 store", () => {
  it("session scope", () => {
    expect(registeredResets("session")).toEqual(
      expect.arrayContaining(["auth.session", "tier3.auth.otp", "tenant.tenant", "tenant.invitations", "tier3.tenant.pin-entry", "shell.prefs"]),
    );
  });
  it("tenant scope", () => {
    expect(registeredResets("tenant")).toEqual(expect.arrayContaining(["tenant.pin-status", "tier3.tenant.pin-entry", "tier3.auth.otp"]));
  });
});
