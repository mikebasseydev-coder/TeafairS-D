import { __setSupabaseForTest } from "./supabase";
import { rpc } from "./rpc";

const KEY = "3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e";

function fakeClient() {
  const calls: { name: string; args: unknown }[] = [];
  const client = { rpc: (name: string, args: unknown) => (calls.push({ name, args }), Promise.resolve({ data: { ok: true }, error: null, status: 200 })) };
  __setSupabaseForTest(client as never);
  return calls;
}

afterEach(() => __setSupabaseForTest(null));

describe("rpc() guards (Spec B §7)", () => {
  it("refuses a tenant id on every RPC but set_active_tenant", async () => {
    fakeClient();
    await expect(rpc("set_tenant_pin", { p_idempotency_key: KEY, p_new_pin: "2580", p_tenant_id: "x" } as never)).rejects.toThrow(/tenant id/);
  });
  it("lets set_active_tenant propose a tenant (Spec A §9's one exception)", async () => {
    const calls = fakeClient();
    const res = await rpc("set_active_tenant", { p_idempotency_key: KEY, p_tenant_id: "7eaf0000-0000-4000-8000-000000000001" });
    expect(res.ok).toBe(true);
    expect(calls[0].name).toBe("set_active_tenant");
  });
  it("refuses a key that is not a UUID v4", async () => {
    fakeClient();
    await expect(rpc("set_tenant_pin", { p_idempotency_key: "not-a-key", p_new_pin: "2580" })).rejects.toThrow(/UUID v4/);
  });
});
