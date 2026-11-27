// A domain status reaches a tone only through a typed adapter in the feature
// that owns it (Spec B §4.2). The Record is exhaustive: a new database status
// breaks the type check until someone maps it.
import { z } from "zod";
import type { SemanticTone } from "@/shared/tokens";

/** monvelo_financings.status, as its CHECK (financing-tone.test.ts holds the two together). */
export const FinancingStatus = z.enum([
  "REQUESTED",
  "AWAITING_APPROVAL",
  "OFFERED",
  "HELD",
  "CLAIMED",
  "FUNDED",
  "DELIVERED",
  "REPAID_WITHIN_WINDOW",
  "REPAID_LATE",
  "DEFAULTED_WITH_LATE_CHARGE",
  "REFUND_DUE",
  "CLOSED_BY_CLAIM",
  "EXPIRED",
  "CANCELLED",
]);
// eslint-disable-next-line @typescript-eslint/no-redeclare -- the schema and its type share a name on purpose
export type FinancingStatus = z.infer<typeof FinancingStatus>;

export const financingTone: Record<FinancingStatus, SemanticTone> = {
  REQUESTED: "pending",
  AWAITING_APPROVAL: "pending",
  OFFERED: "info",
  HELD: "warning",
  CLAIMED: "brand",
  FUNDED: "brand",
  DELIVERED: "brand",
  REPAID_WITHIN_WINDOW: "success",
  REPAID_LATE: "warning",
  DEFAULTED_WITH_LATE_CHARGE: "danger",
  REFUND_DUE: "danger",
  CLOSED_BY_CLAIM: "neutral",
  EXPIRED: "neutral",
  CANCELLED: "neutral",
};

/** The words a badge shows; status is never colour alone. */
export const financingLabel: Record<FinancingStatus, string> = {
  REQUESTED: "Requested",
  AWAITING_APPROVAL: "Awaiting approval",
  OFFERED: "Offered",
  HELD: "Held",
  CLAIMED: "Claimed",
  FUNDED: "Funded",
  DELIVERED: "Delivered",
  REPAID_WITHIN_WINDOW: "Repaid",
  REPAID_LATE: "Repaid late",
  DEFAULTED_WITH_LATE_CHARGE: "Defaulted",
  REFUND_DUE: "Refund due",
  CLOSED_BY_CLAIM: "Closed by claim",
  EXPIRED: "Expired",
  CANCELLED: "Cancelled",
};
