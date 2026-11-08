import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { adapterFor } from "../_shared/insurance/registry.ts";
import { createMonveloInsuranceDeclareHandler } from "./handler.ts";

// system-flavoured (§3.4, Ruling 46): invoked by pg_cron via pg_net with x-cron-secret
const cronSecret = requireEnv("CRON_SECRET");

Deno.serve(observe("monvelo-insurance-declare", createMonveloInsuranceDeclareHandler({
  cronSecret,
  rpc: serviceRpc(),
  adapterFor: (p) => adapterFor(p),
})));
