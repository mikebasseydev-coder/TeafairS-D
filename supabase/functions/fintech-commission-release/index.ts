import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import {
  paystackSettlementLister,
  paystackSettlementTransactionLister,
  paystackSubaccountFetcher,
} from "../_shared/fintech-liquidity/paystack-settlements.ts";
import { createCommissionReleaseHandler } from "./handler.ts";

// system-flavoured (§3.4): invoked by pg_cron via pg_net with x-cron-secret
const cronSecret = requireEnv("CRON_SECRET");
const secretKey = requireEnv("PAYSTACK_SECRET_KEY");
const baseUrl = Deno.env.get("PAYSTACK_API_BASE") || undefined;

Deno.serve(createCommissionReleaseHandler({
  cronSecret,
  rpc: serviceRpc(),
  fetchSubaccountId: paystackSubaccountFetcher({ secretKey, baseUrl }),
  listSettlements: paystackSettlementLister({ secretKey, baseUrl }),
  listSettlementTransactions: paystackSettlementTransactionLister({ secretKey, baseUrl }),
}));
