// The MANUAL insurer (A8 §7.4): an operator sends the declaration by hand and
// records the insurer's answer with record_monvelo_declaration_outcome. A
// manual insurer never calls in, so its webhook never verifies.
import type { InsurerAdapter } from "./adapter.ts";

export const manualAdapter: InsurerAdapter = {
  send: () => Promise.resolve({ outcome: "QUEUED_MANUAL" }),
  verifyWebhook: () => Promise.resolve(false),
  parseEvent: () => {
    throw new Error("a manual insurer sends no events");
  },
};
