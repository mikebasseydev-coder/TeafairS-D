// Sentry for the Edge Functions. Off unless SENTRY_DSN is set, so tests and
// local runs send nothing. Every event, transaction and breadcrumb passes
// through scrub.ts before it leaves the runtime.
//
// What becomes an event:
// - any 5xx, and anything thrown that is not a GatewayError: level error;
// - a database refusal (P0001, 42501, 23505, 23514, TF001, TF002): level
//   warning, one issue per RPC + SQLSTATE + message shape;
// - nothing else (bad input, no JWT, 404s are the caller's business).
import { Sentry } from "./deps.ts";
import { scrubBreadcrumb, scrubEvent } from "./scrub.ts";

type Attributes = Record<string, string | number | boolean>;

export type ObservabilityOptions = {
  dsn?: string;
  environment?: string;
  release?: string;
  tracesSampleRate?: number;
  /** Tests only: a Sentry transport factory that records envelopes. */
  transport?: unknown;
};

let state: "off" | "on" | null = null;

function sampleRate(): number {
  const raw = Number(Deno.env.get("SENTRY_TRACES_SAMPLE_RATE") ?? "1");
  return Number.isFinite(raw) && raw >= 0 && raw <= 1 ? raw : 1;
}

/** Initialises Sentry once per isolate; later calls are no-ops. */
export function initObservability(options: ObservabilityOptions = {}): boolean {
  if (state !== null) return state === "on";
  const dsn = options.dsn ?? Deno.env.get("SENTRY_DSN") ?? "";
  if (!dsn) {
    state = "off";
    return false;
  }
  Sentry.init({
    dsn,
    environment: options.environment ?? (Deno.env.get("SENTRY_ENVIRONMENT") || "local"),
    release: options.release ?? (Deno.env.get("SENTRY_RELEASE") || undefined),
    tracesSampleRate: options.tracesSampleRate ?? sampleRate(),
    sendDefaultPii: false,
    // The edge runtime has no Deno.serve instrumentation: observe() opens the
    // request transaction itself, and no default integration reads globals.
    defaultIntegrations: false,
    integrations: [],
    beforeSend: (event) => scrubEvent(event),
    beforeSendTransaction: (event) => scrubEvent(event),
    beforeBreadcrumb: (crumb) => scrubBreadcrumb(crumb),
    // deno-lint-ignore no-explicit-any
    ...(options.transport ? { transport: options.transport as any } : {}),
  });
  state = "on";
  return true;
}

function enabled(): boolean {
  return state === null ? initObservability() : state === "on";
}

/** Tests only: forget the initialisation so a test can init again. */
export function resetObservabilityForTests(): void {
  state = null;
}

function background(p: Promise<unknown>): Promise<void> {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(p);
    return Promise.resolve();
  }
  return p.then(() => undefined);
}

/**
 * Wraps a function's request handler: continues the caller's trace
 * (sentry-trace and baggage headers), opens one http.server transaction per
 * request, and flushes after the response without delaying it.
 */
export function observe(
  name: string,
  handler: (req: Request) => Promise<Response> | Response,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (!enabled()) return await handler(req);
    try {
      return await Sentry.withIsolationScope((scope) => {
        scope.setTag("function", name);
        const region = Deno.env.get("SB_REGION");
        if (region) scope.setTag("region", region);
        const execution = Deno.env.get("SB_EXECUTION_ID");
        if (execution) scope.setTag("execution_id", execution);
        return Sentry.continueTrace(
          {
            sentryTrace: req.headers.get("sentry-trace") ?? undefined,
            baggage: req.headers.get("baggage") ?? undefined,
          },
          () =>
            Sentry.startSpan(
              {
                name: `${req.method} /${name}`,
                op: "http.server",
                forceTransaction: true,
                attributes: { "http.request.method": req.method, "faas.name": name },
              },
              async (span) => {
                try {
                  const response = await handler(req);
                  Sentry.setHttpStatus(span, response.status);
                  return response;
                } catch (e) {
                  Sentry.setHttpStatus(span, 500);
                  reportError(e);
                  throw e;
                }
              },
            ),
        );
      });
    } finally {
      await background(Sentry.flush(2000));
    }
  };
}

/** A child span of the current request; a plain call when Sentry is off. */
export function traced<T>(name: string, op: string, attributes: Attributes, fn: () => Promise<T>): Promise<T> {
  if (!enabled()) return fn();
  return Sentry.startSpan({ name, op, attributes }, () => fn());
}

/** Marks the current span with an attribute (e.g. the SQLSTATE of a refusal). */
export function annotateSpan(attributes: Attributes): void {
  if (!enabled()) return;
  Sentry.getActiveSpan()?.setAttributes(attributes);
}

/** Request-level tags, e.g. the gateway flavour. */
export function tagRequest(tags: Record<string, string>): void {
  if (!enabled()) return;
  Sentry.getIsolationScope().setTags(tags);
}

/** The authenticated caller: tenant, roles and user id (no other PII). */
export function tagCaller(caller: {
  userId: string;
  activeTenantId: string | null;
  tenantRole: string | null;
  platformRole: string | null;
}): void {
  if (!enabled()) return;
  const scope = Sentry.getIsolationScope();
  scope.setUser({ id: caller.userId });
  scope.setTags({
    tenant_id: caller.activeTenantId ?? "none",
    tenant_role: caller.tenantRole ?? "none",
    ...(caller.platformRole ? { platform_role: caller.platformRole } : {}),
  });
}

const DB_REFUSALS = new Set(["P0001", "42501", "23505", "23514", "TF001", "TF002"]);

type Reportable = { status?: unknown; code?: unknown; sqlstate?: unknown; rpcFunction?: unknown; message?: unknown };

/** Applies the capture policy above. Safe to call for any error. */
export function reportError(e: unknown): void {
  if (!enabled()) return;
  const g = (e ?? {}) as Reportable;
  const status = typeof g.status === "number" ? g.status : 500;
  const sqlstate = typeof g.sqlstate === "string" ? g.sqlstate : null;
  const rpcFunction = typeof g.rpcFunction === "string" ? g.rpcFunction : null;
  const tags: Record<string, string> = {
    "http.status_code": String(status),
    ...(typeof g.code === "string" ? { error_code: g.code } : {}),
    ...(sqlstate ? { "db.sqlstate": sqlstate } : {}),
    ...(rpcFunction ? { "rpc.function": rpcFunction } : {}),
  };
  if (status >= 500) {
    Sentry.captureException(e, { level: "error", tags });
    return;
  }
  if (sqlstate && DB_REFUSALS.has(sqlstate)) {
    const shape = typeof g.message === "string" ? g.message.replace(/\d+(\.\d+)?/g, "N") : "";
    Sentry.captureException(e, {
      level: "warning",
      tags,
      fingerprint: ["db-refusal", rpcFunction ?? "unknown", sqlstate, shape],
    });
  }
}
