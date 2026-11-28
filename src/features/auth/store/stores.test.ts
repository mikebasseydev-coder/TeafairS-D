import { onAppStateChange } from "@/shared/storage/tier3";
import { runResets } from "@/shared/storage/reset-registry";
import { useOtpStore } from "./otp-store";
import { useSessionStore } from "./session-store";

const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
const token = (meta: object) => `${b64({ alg: "none" })}.${b64({ sub: "u-1", exp: 9e9, app_metadata: meta })}.sig`;

describe("useSessionStore", () => {
  it("decodes the claims as hints and signs out on a null token", () => {
    useSessionStore.getState().setAccessToken(token({ active_tenant_id: "t-1", tenant_ids: ["t-1"], tenant_role: "TM" }));
    expect(useSessionStore.getState()).toMatchObject({ status: "signedIn", userId: "u-1" });
    expect(useSessionStore.getState().claims.tenantRole).toBe("TM");
    useSessionStore.getState().setAccessToken(null);
    expect(useSessionStore.getState()).toMatchObject({ status: "signedOut", userId: null });
  });
});

describe("useOtpStore (Tier 3)", () => {
  it("the background drops the code but keeps the email step; sign-out wipes everything", async () => {
    useOtpStore.getState().codeSent("a@b.co", 0);
    useOtpStore.getState().setCode("123");
    onAppStateChange("background");
    expect(useOtpStore.getState()).toMatchObject({ step: "code", email: "a@b.co", code: "" });
    await runResets("session");
    expect(useOtpStore.getState()).toMatchObject({ step: "email", email: "", code: "", resendAvailableAt: null });
  });
  it("a code may be resent only after 60 s", () => {
    useOtpStore.getState().codeSent("a@b.co", 1000);
    expect(useOtpStore.getState().resendAvailableAt).toBe(61_000);
  });
});
