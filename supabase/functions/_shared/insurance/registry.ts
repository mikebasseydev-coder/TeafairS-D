// The adapter for an insurer's api_provider. MYCOVER is allowed by the
// table's CHECK for later, but has no adapter (A8 decision 8): it throws, and
// the declare function retries the row until an operator acts.
import type { ApiProvider, InsurerAdapter } from "./adapter.ts";
import { manualAdapter } from "./manual.ts";
import { createMockAdapter } from "./mock.ts";

export type AdapterConfig = { mockSecret?: string };

export function adapterFor(apiProvider: ApiProvider, config: AdapterConfig = {}): InsurerAdapter {
  switch (apiProvider) {
    case "MOCK":
      return createMockAdapter({ secret: config.mockSecret ?? Deno.env.get("MONVELO_MOCK_INSURER_SECRET") ?? "" });
    case "MANUAL":
      return manualAdapter;
    default:
      throw new Error(`no insurer adapter for ${String(apiProvider)}`);
  }
}
