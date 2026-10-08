// Spec A §3.5 — the error contract. The offline queue decides retry vs stop
// from the status alone, so this table is the contract, not a convenience.
import { json } from "./http.ts";

export class GatewayError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details: unknown = null,
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

export type PostgresError = { code?: string; message?: string; details?: string | null };

const CONTRACT: Record<string, { status: number; code: string }> = {
  P0001: { status: 422, code: "BUSINESS_RULE" },
  "42501": { status: 403, code: "FORBIDDEN" },
  "23505": { status: 409, code: "CONFLICT" },
  TF001: { status: 409, code: "INSUFFICIENT_STOCK" },
  TF002: { status: 409, code: "IDEMPOTENCY_MISMATCH" },
  "40001": { status: 503, code: "RETRY" },
  "55P03": { status: 503, code: "RETRY" },
  // PostgREST: the JWT expired between the gateway's check and the RPC
  PGRST301: { status: 401, code: "UNAUTHENTICATED" },
};

const GENERIC = "Something went wrong. Please try again.";

export function mapPostgresError(err: PostgresError): GatewayError {
  const hit = err.code ? CONTRACT[err.code] : undefined;
  if (!hit) {
    console.error("unmapped database error", err);
    return new GatewayError(500, "INTERNAL", GENERIC);
  }
  const message = hit.status === 503
    ? "The server is busy. Please try again."
    : hit.status === 401
    ? "Sign in to continue."
    : (err.message ?? hit.code);
  return new GatewayError(hit.status, hit.code, message, parseDetails(err.details));
}

function parseDetails(details: string | null | undefined): unknown {
  if (!details) return null;
  try {
    return JSON.parse(details);
  } catch {
    return details;
  }
}

export function errorResponse(e: unknown): Response {
  if (e instanceof GatewayError) {
    return json(e.status, { error: { code: e.code, message: e.message, details: e.details } });
  }
  console.error(e);
  return json(500, { error: { code: "INTERNAL", message: GENERIC, details: null } });
}
