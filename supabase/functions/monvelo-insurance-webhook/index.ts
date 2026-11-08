import { serviceRpc } from "../_shared/core/db.ts";
import { observe } from "../_shared/core/observability.ts";
import { adapterFor } from "../_shared/insurance/registry.ts";
import { createMonveloInsuranceWebhookHandler } from "./handler.ts";

// public (Ruling 46): the insurer's adapter verifies its HMAC before any
// service RPC except the insurer's adapter lookup
Deno.serve(observe("monvelo-insurance-webhook", createMonveloInsuranceWebhookHandler({
  rpc: serviceRpc(),
  adapterFor: (p) => adapterFor(p),
})));
