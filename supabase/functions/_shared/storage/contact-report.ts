// Addendum A6 §16.4 — the signed hard copy of a contact report.
import { z } from "../core/deps.ts";

export const CONTACT_REPORT_BUCKET = "contact-reports";
export const MAX_HARD_COPY_BYTES = 10_485_760;

export const hardCopyFields = {
  mime_type: z.enum(["application/pdf", "image/jpeg", "image/png"]),
  size_bytes: z.number().int().min(1).max(MAX_HARD_COPY_BYTES),
};
