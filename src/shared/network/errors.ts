// The §3.5 error contract, normalised by SQLSTATE, not HTTP status (Spec B §7).
// PostgREST returns P0001 as 400 and 40001 as 500, so a direct RPC error is
// classified from its `code`; gateways already map §3.5 to HTTP.

export type ErrorClass = "business" | "forbidden" | "conflict" | "transient" | "session";

export type AppError = {
  code: string;
  http: number;
  message: string;
  details: unknown;
  terminal: boolean;
  class: ErrorClass;
};

export type Result<T> = { ok: true; data: T } | { ok: false; error: AppError };

const BY_CODE: Record<string, { http: number; class: ErrorClass }> = {
  P0001: { http: 422, class: "business" },
  "42501": { http: 403, class: "forbidden" },
  "23505": { http: 409, class: "conflict" },
  TF001: { http: 409, class: "conflict" },
  TF002: { http: 409, class: "conflict" },
  "40001": { http: 503, class: "transient" },
  "55P03": { http: 503, class: "transient" },
};

const JWT_CODES = new Set(["PGRST301", "PGRST302", "PGRST303"]);

function make(code: string, http: number, cls: ErrorClass, message: string, details: unknown): AppError {
  return { code, http, message, details, class: cls, terminal: cls !== "transient" && cls !== "session" };
}

/** A PostgREST (supabase.rpc) error: `{ code, message, details, hint }` plus the HTTP status. */
export function fromPostgrest(err: { code?: string; message?: string; details?: unknown } | null, status?: number): AppError {
  const code = err?.code ?? "";
  const message = err?.message ?? "Request failed";
  if (JWT_CODES.has(code) || status === 401) return make(code || "UNAUTHORIZED", 401, "session", message, err?.details);
  const known = BY_CODE[code];
  if (known) return make(code, known.http, known.class, message, err?.details);
  if (status !== undefined && status >= 400 && status < 500) return make(code || `HTTP_${status}`, status, "business", message, err?.details);
  return make(code || "NETWORK", status ?? 0, "transient", message, err?.details);
}

/** A gateway reply in Spec A's shape: `{ error: { code, message, details } }` with the mapped HTTP status. */
export function fromGateway(status: number, body: { error?: { code?: string; message?: string; details?: unknown } } | null): AppError {
  const e = body?.error ?? {};
  const code = e.code ?? `HTTP_${status}`;
  const message = e.message ?? "Request failed";
  if (status === 401) return make(code, 401, "session", message, e.details);
  if (status === 403) return make(code, 403, "forbidden", message, e.details);
  if (status === 409) return make(code, 409, "conflict", message, e.details);
  if (status === 422 || status === 400) return make(code, status, "business", message, e.details);
  return make(code, status, "transient", message, e.details);
}

export function networkError(message = "Network unavailable"): AppError {
  return make("NETWORK", 0, "transient", message, null);
}
