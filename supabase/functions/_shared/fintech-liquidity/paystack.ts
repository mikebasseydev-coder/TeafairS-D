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

// Addendum A1 §5.3 step 4 — Initialize Transaction. Amount, split and charge
// are computed on the server; with bearer "account" the main account bears
// Paystack's fee and the subaccount receives amount − transaction_charge.
export type InitializeRequest = {
  reference: string;
  amountMinor: number;
  currency: string;
  email: string;
  callbackUrl: string;
  metadata: Record<string, unknown>;
  split?: { subaccount: string; transactionChargeMinor: number };
};
export type InitializedTransaction = { reference: string; accessCode: string; authorizationUrl: string };
export type InitializeTransaction = (req: InitializeRequest) => Promise<InitializedTransaction>;

const initializeResponse = z.object({
  status: z.literal(true),
  data: z.object({
    authorization_url: z.string().url(),
    access_code: z.string(),
    reference: z.string(),
  }),
});

export function paystackInitializer(opts: {
  secretKey: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}): InitializeTransaction {
  const fetchFn = opts.fetchFn ?? fetch;
  const timeoutMs = opts.timeoutMs ?? 15000;
  const baseUrl = opts.baseUrl ?? "https://api.paystack.co";
  return async (req) => {
    const body: Record<string, unknown> = {
      reference: req.reference,
      amount: req.amountMinor,
      currency: req.currency,
      email: req.email,
      callback_url: req.callbackUrl,
      metadata: req.metadata,
    };
    if (req.split) {
      body.subaccount = req.split.subaccount;
      body.transaction_charge = req.split.transactionChargeMinor;
      body.bearer = "account";
    }
    const res = await fetchFn(`${baseUrl}/transaction/initialize`, {
      method: "POST",
      headers: { Authorization: `Bearer ${opts.secretKey}`, "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const payload = await res.json().catch(() => null) as { message?: string } | null;
    const parsed = initializeResponse.safeParse(payload);
    if (!res.ok || !parsed.success) {
      throw new Error(`Paystack initialize failed: ${payload?.message ?? `HTTP ${res.status}`}`);
    }
    const { data } = parsed.data;
    return { reference: data.reference, accessCode: data.access_code, authorizationUrl: data.authorization_url };
  };
}
