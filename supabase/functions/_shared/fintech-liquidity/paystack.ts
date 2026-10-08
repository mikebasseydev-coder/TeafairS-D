// Spec A §3.6 check 3 / §6.11: amount, currency and status come from the
// Verify Transaction API, never from a webhook body or a client.
import { z } from "../core/deps.ts";

export type VerifiedTransaction = {
  status: string;
  reference: string;
  amountMinor: number;
  currency: string;
  raw: Record<string, unknown>;
};
export type VerifyTransaction = (reference: string) => Promise<VerifiedTransaction>;

const verifyResponse = z.object({
  status: z.literal(true),
  data: z.object({
    status: z.string(),
    reference: z.string(),
    amount: z.number().int(),
    currency: z.string(),
  }).passthrough(),
});

export function paystackVerifier(opts: {
  secretKey: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
}): VerifyTransaction {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://api.paystack.co";
  return async (reference) => {
    const res = await fetchFn(`${baseUrl}/transaction/verify/${encodeURIComponent(reference)}`, {
      headers: { Authorization: `Bearer ${opts.secretKey}` },
    });
    const payload = await res.json().catch(() => null) as { message?: string } | null;
    const parsed = verifyResponse.safeParse(payload);
    if (!res.ok || !parsed.success) {
      throw new Error(`Paystack verify failed: ${payload?.message ?? `HTTP ${res.status}`}`);
    }
    const { data } = parsed.data;
    return {
      status: data.status,
      reference: data.reference,
      amountMinor: data.amount,
      currency: data.currency,
      raw: data,
    };
  };
}
