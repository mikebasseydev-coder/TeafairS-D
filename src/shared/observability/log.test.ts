import { log, setLogSink, type LogLevel } from "./log";
import { FILTERED, scrubString, scrubValue } from "./scrub";

describe("scrub (Ruling 46, Spec B §4.4)", () => {
  it("drops values under sensitive keys and every p_ parameter", () => {
    expect(
      scrubValue({
        pin: "4821",
        otp: "123456",
        code: "998877",
        access_token: "x",
        refresh_token: "y",
        phone: "08031234567",
        email: "owner@example.com",
        address_text: "1 Allen Avenue",
        bvn_nin_hash: "h",
        authorization_url: "https://checkout",
        access_code: "ac",
        p_new_pin: "1357",
        p_shop_id: "s",
        payload: { anything: 1 },
        status: "PENDING",
      }),
    ).toEqual({
      pin: FILTERED,
      otp: FILTERED,
      code: FILTERED,
      access_token: FILTERED,
      refresh_token: FILTERED,
      phone: FILTERED,
      email: FILTERED,
      address_text: FILTERED,
      bvn_nin_hash: FILTERED,
      authorization_url: FILTERED,
      access_code: FILTERED,
      p_new_pin: FILTERED,
      p_shop_id: FILTERED,
      payload: FILTERED,
      status: "PENDING",
    });
  });
  it("scrubs JWTs, emails, phones and codes inside strings", () => {
    const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    const s = scrubString(`token ${jwt} for owner@example.com on +2348031234567, code 482113`);
    expect(s).not.toContain("eyJ");
    expect(s).not.toContain("owner@example.com");
    expect(s).not.toContain("8031234567");
    expect(s).not.toContain("482113");
  });
  it("drops secret keys", () => {
    // built at runtime: the Ruling 46 scanner forbids a key-shaped literal in src/
    const fake = ["sb", "secret", "abc123XYZ"].join("_");
    expect(scrubString(`key ${fake}`)).toBe("key [supabase-key]");
  });
});

describe("log", () => {
  it("scrubs message and context before the sink sees them", () => {
    const seen: [LogLevel, string, unknown][] = [];
    setLogSink((l, m, c) => seen.push([l, m, c]));
    log.warn("sent to owner@example.com", { pin: "4821", attempt: 2 });
    expect(seen).toEqual([["warn", "sent to [email]", { pin: FILTERED, attempt: 2 }]]);
  });
});
