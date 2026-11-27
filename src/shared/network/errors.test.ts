import { fromGateway, fromPostgrest, networkError } from "./errors";

describe("fromPostgrest classifies by SQLSTATE (Spec B §7)", () => {
  it.each([
    ["P0001", 400, 422, "business", true],
    ["42501", 403, 403, "forbidden", true],
    ["23505", 409, 409, "conflict", true],
    ["TF001", 400, 409, "conflict", true],
    ["TF002", 400, 409, "conflict", true],
    ["40001", 500, 503, "transient", false],
    ["55P03", 500, 503, "transient", false],
  ] as const)("%s (HTTP %s) → %s %s", (code, status, http, cls, terminal) => {
    const e = fromPostgrest({ code, message: "m" }, status);
    expect(e).toMatchObject({ code, http, class: cls, terminal, message: "m" });
  });
  it("keeps the database copy as written", () => {
    expect(fromPostgrest({ code: "P0001", message: "the shop owner has no verified email" }, 400).message).toBe(
      "the shop owner has no verified email",
    );
  });
  it("an expired JWT is a session error, not terminal", () => {
    expect(fromPostgrest({ code: "PGRST303", message: "JWT expired" }, 401)).toMatchObject({ class: "session", terminal: false });
  });
  it("a 5xx without a known code is transient", () => {
    expect(fromPostgrest({ message: "boom" }, 502)).toMatchObject({ class: "transient", terminal: false });
  });
  it("a network failure is transient", () => {
    expect(networkError()).toMatchObject({ class: "transient", terminal: false, http: 0 });
  });
});

describe("fromGateway", () => {
  it("422 WRONG_PIN is terminal business", () => {
    expect(fromGateway(422, { error: { code: "WRONG_PIN", message: "x" } })).toMatchObject({ class: "business", terminal: true });
  });
  it("409 MONVELO_CHECKOUT_LOST is a terminal conflict", () => {
    expect(fromGateway(409, { error: { code: "MONVELO_CHECKOUT_LOST", message: "x" } })).toMatchObject({ class: "conflict", terminal: true });
  });
  it("502 MESSAGE_DELIVERY_FAILED is transient", () => {
    expect(fromGateway(502, { error: { code: "MESSAGE_DELIVERY_FAILED", message: "x" } })).toMatchObject({ terminal: false });
  });
});
