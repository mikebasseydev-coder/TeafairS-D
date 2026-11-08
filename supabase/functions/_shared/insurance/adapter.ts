// Addendum A8 §7.4: one interface per insurer integration. The database
// builds every payload (references, amounts and dates only) and decides
// every amount; an adapter only carries it to the insurer and back.
// Only MOCK and MANUAL exist (user decision 8, 2026-11-07): no real insurer
// API code until a contract names one.

export type DeclarationKind = "GIT_DECLARE" | "STORAGE_DECLARE" | "STORAGE_CANCEL" | "CLAIM_FILE";

export type SendResult =
  | { outcome: "ACCEPTED"; insurerReference: string }
  | { outcome: "REJECTED"; insurerReference: string | null; error: string }
  | { outcome: "RETRY"; error: string }
  // MANUAL: an operator sends it by hand and records the answer
  | { outcome: "QUEUED_MANUAL" };

export type InsurerEvent = {
  eventId: string;
  type: string;
  claimReference?: string;
  declarationId?: string;
  settledAmount?: string;
  payoutReference?: string;
  insurerReference?: string;
};

export interface InsurerAdapter {
  send(kind: DeclarationKind, payload: Record<string, unknown>, idempotencyKey: string): Promise<SendResult>;
  verifyWebhook(req: Request, rawBody: string): Promise<boolean>;
  parseEvent(rawBody: string): InsurerEvent;
}

export type ApiProvider = "MOCK" | "MANUAL";
