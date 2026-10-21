import { GatewayError } from "../core/errors.ts";

// The RPCs raise P0001 NOT_FOUND for a miss; rpc() maps that to a 422
// GatewayError carrying the same message. Turn it into a plain 404.
export function mapNotFound(e: unknown, message: string): unknown {
  return e instanceof GatewayError && e.status === 422 && e.message === "NOT_FOUND"
    ? new GatewayError(404, "NOT_FOUND", message)
    : e;
}
