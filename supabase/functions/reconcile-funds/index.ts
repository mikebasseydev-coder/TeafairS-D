import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { paystackVerifier } from "../_shared/fintech-liquidity/paystack.ts";
import { paystackRefundLister } from "../_shared/fintech-liquidity/paystack-refunds.ts";
import { createReconcileFundsHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// system-flavoured (§3.4): invoked by pg_cron via pg_net with x-cron-secret
const cronSecret = requireEnv("CRON_SECRET");
const secretKey = requireEnv("PAYSTACK_SECRET_KEY");
const baseUrl = Deno.env.get("PAYSTACK_API_BASE") || undefined;

Deno.serve(observe("reconcile-funds", createReconcileFundsHandler({
  cronSecret,
  rpc: serviceRpc(),
  verifyTransaction: paystackVerifier({ secretKey, baseUrl }),
  listRefunds: paystackRefundLister({ secretKey, baseUrl }),
  now: () => new Date(),
})));
