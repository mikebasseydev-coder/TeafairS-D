// Resolve Teafair's POS agents' settlement accounts against Paystack
// (Addendum A6 §6.3). Teafair does no KYC of its own; this only proves the
// account exists and returns the name the bank holds for it.
import { z } from "../core/deps.ts";
import { GatewayError } from "../core/errors.ts";
import { type PaystackOpts, paystackGet } from "../payments/paystack-client.ts";

const response = z.object({
  status: z.boolean(),
  data: z.object({ account_name: z.string().optional() }).passthrough().nullish(),
}).passthrough();

const NOT_RESOLVED = "That bank account could not be verified.";

export async function resolveAccount(
  opts: PaystackOpts,
  accountNumber: string,
  bankCode: string,
): Promise<{ accountName: string }> {
  // paystackGet throws one generic Error for every failure; record the HTTP
  // status so a rejected account (4xx) is told apart from an outage.
  let httpStatus = 0;
  const base = opts.fetchFn ?? fetch;
  const fetchFn: typeof fetch = async (input, init) => {
    const res = await base(input, init);
    httpStatus = res.status;
    return res;
  };
  let reply: z.infer<typeof response>;
  try {
    reply = await paystackGet(
      { ...opts, fetchFn },
      "/bank/resolve",
      { account_number: accountNumber, bank_code: bankCode },
      response,
    );
  } catch {
    // never log or return the error: Paystack's text and our query hold the account number
    if (httpStatus === 400 || httpStatus === 404 || httpStatus === 422) {
      throw new GatewayError(422, "ACCOUNT_NOT_RESOLVED", NOT_RESOLVED);
    }
    throw new GatewayError(502, "BANK_VERIFICATION_UNAVAILABLE", "Bank verification is unavailable. Please try again.");
  }
  const name = reply.data?.account_name?.trim();
  if (!reply.status) throw new GatewayError(422, "ACCOUNT_NOT_RESOLVED", NOT_RESOLVED);
  if (!name) throw new GatewayError(502, "BANK_VERIFICATION_UNAVAILABLE", "Bank verification is unavailable. Please try again.");
  return { accountName: name };
}
