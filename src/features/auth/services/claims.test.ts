import { decodeClaims } from "./claims";

const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (payload: unknown) => `${enc({ alg: "HS256" })}.${enc(payload)}.sig`;

describe("decodeClaims (Spec B §9.2)", () => {
  it("reads app_metadata", () => {
    const c = decodeClaims(
      jwt({
        sub: "u1",
        exp: 100,
        app_metadata: { tenant_ids: ["t1", "t2"], active_tenant_id: "t1", tenant_role: "ZSA", platform_role: "MONVELO_OPERATOR" },
      }),
    );
    expect(c).toEqual({
      userId: "u1",
      tenantIds: ["t1", "t2"],
      activeTenantId: "t1",
      tenantRole: "ZSA",
      platformRole: "MONVELO_OPERATOR",
      expiresAt: 100,
    });
  });
  it("drops a role outside the two enums", () => {
    const c = decodeClaims(jwt({ sub: "u", app_metadata: { tenant_role: "AGENT", platform_role: "ADMIN" } }));
    expect(c.tenantRole).toBeNull();
    expect(c.platformRole).toBeNull();
  });
  it.each([null, "", "a.b", "a.!!!.c", "x.y.z"])("malformed %p decodes to no claims", (t) => {
    expect(decodeClaims(t as string | null)).toMatchObject({ userId: null, tenantIds: [], tenantRole: null });
  });
});
