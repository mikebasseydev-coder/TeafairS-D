import { __setSupabaseForTest } from "@/shared/network/supabase";
import { __clearResetsForTest, registerReset } from "@/shared/storage/reset-registry";
import { AUTH_COPY, classifyAuthError, requestCode, signOut, verifyCode } from "./auth-service";

afterEach(() => {
  __setSupabaseForTest(null);
  __clearResetsForTest();
});

describe("auth error classification (Spec B §9.1)", () => {
  it("an unknown person refused by the hook is no access", () => {
    expect(classifyAuthError({ status: 403, code: undefined }, "request")).toBe("no_access");
  });
  it("a wrong or expired code is invalid", () => {
    expect(classifyAuthError({ status: 403, code: "otp_expired" }, "verify")).toBe("invalid_code");
  });
  it("an unknown email (Auth's own 422 otp_disabled) is no access", () => {
    expect(classifyAuthError({ status: 422, code: "otp_disabled" }, "request")).toBe("no_access");
  });
  it("a hook timeout is busy, never no access", () => {
    expect(classifyAuthError({ status: 422, code: "hook_timeout" }, "request")).toBe("busy");
    expect(classifyAuthError({ status: 422, code: "hook_timeout" }, "verify")).toBe("busy");
  });
  it("rate limits are named", () => {
    expect(classifyAuthError({ status: 429, code: "over_email_send_rate_limit" }, "request")).toBe("rate_limited");
  });
  it("the copy for no access is the access message", () => {
    expect(AUTH_COPY.no_access).toBe("This email has no Teafair access.");
  });
});

describe("the email-first calls", () => {
  it("never creates a user and asks for an email code", async () => {
    const signInWithOtp = jest.fn().mockResolvedValue({ error: null });
    const verifyOtp = jest.fn().mockResolvedValue({ error: null });
    __setSupabaseForTest({ auth: { signInWithOtp, verifyOtp } } as never);
    expect(await requestCode("a@b.co")).toEqual({ ok: true });
    expect(signInWithOtp).toHaveBeenCalledWith({ email: "a@b.co", options: { shouldCreateUser: false } });
    expect(await verifyCode("a@b.co", "123456")).toEqual({ ok: true });
    expect(verifyOtp).toHaveBeenCalledWith({ email: "a@b.co", token: "123456", type: "email" });
  });
  it("a thrown fetch is a network failure", async () => {
    __setSupabaseForTest({ auth: { signInWithOtp: jest.fn().mockRejectedValue(new Error("offline")) } } as never);
    expect(await requestCode("a@b.co")).toEqual({ ok: false, failure: { kind: "network", message: AUTH_COPY.network } });
  });
});

describe("sign-out (Spec B §5)", () => {
  it("runs every reset before Auth drops the session", async () => {
    const order: string[] = [];
    registerReset("tenant", "t", () => void order.push("tenant"));
    registerReset("session", "s", () => void order.push("session"));
    __setSupabaseForTest({ auth: { signOut: jest.fn(async () => void order.push("auth.signOut")) } } as never);
    await signOut();
    expect(order).toEqual(["tenant", "session", "auth.signOut"]);
  });
});
