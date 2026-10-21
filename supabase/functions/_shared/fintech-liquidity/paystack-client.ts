// Shared GET + pagination for Paystack list endpoints (Spec D1 §12).
import { z } from "../core/deps.ts";

export type PaystackOpts = { secretKey: string; baseUrl?: string; fetchFn?: typeof fetch; timeoutMs?: number };

const MAX_PAGES = 50;
const PER_PAGE = 100;

export async function paystackGet<T>(
  opts: PaystackOpts,
  path: string,
  query: Record<string, string | number | undefined>,
  schema: z.ZodType<T>,
): Promise<T> {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://api.paystack.co";
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) if (v !== undefined) qs.set(k, String(v));
  const q = qs.toString();
  const res = await fetchFn(`${baseUrl}${path}${q ? `?${q}` : ""}`, {
    headers: { Authorization: `Bearer ${opts.secretKey}` },
    signal: AbortSignal.timeout(opts.timeoutMs ?? 15000),
  });
  const payload = await res.json().catch(() => null) as { message?: string } | null;
  const parsed = schema.safeParse(payload);
  if (!res.ok || !parsed.success) {
    const issue = !parsed.success ? parsed.error.issues[0] : undefined;
    const shape = issue ? `unexpected response shape at ${issue.path.join(".") || "(root)"}` : undefined;
    throw new Error(`Paystack ${path} failed: ${payload?.message ?? shape ?? `HTTP ${res.status}`}`);
  }
  return parsed.data;
}

export async function paystackPages<T>(
  opts: PaystackOpts,
  path: string,
  query: Record<string, string | number | undefined>,
  item: z.ZodType<T>,
): Promise<T[]> {
  const schema = z.object({
    status: z.literal(true),
    data: z.array(item),
    meta: z.object({ pageCount: z.number().int().nonnegative() }).passthrough(),
  });
  const out: T[] = [];
  let pageCount = 1;
  for (let page = 1; page <= pageCount; page++) {
    const r = await paystackGet(opts, path, { ...query, perPage: PER_PAGE, page }, schema);
    if (r.meta.pageCount > MAX_PAGES) {
      throw new Error(`Paystack ${path} failed: more than ${MAX_PAGES * PER_PAGE} results`);
    }
    out.push(...r.data);
    pageCount = r.meta.pageCount;
  }
  return out;
}
