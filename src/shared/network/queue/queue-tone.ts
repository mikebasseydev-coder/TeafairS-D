// The queue's statuses (Spec B §8) and their tones (§4.2). The queue itself is
// built in slice B4.
import type { SemanticTone } from "@/shared/tokens";

export type QueueStatus = "PENDING" | "IN_FLIGHT" | "TERMINAL" | "DONE";

export const queueTone: Record<QueueStatus, SemanticTone> = {
  PENDING: "pending",
  IN_FLIGHT: "info",
  TERMINAL: "danger",
  DONE: "success",
};

export const queueLabel: Record<QueueStatus, string> = {
  PENDING: "Queued",
  IN_FLIGHT: "Sending",
  TERMINAL: "Needs attention",
  DONE: "Sent",
};
