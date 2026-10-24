// Addendum A5 §4 — photo limits shared by the attachment gateways.
import { z } from "../core/deps.ts";

export const ATTACHMENT_BUCKET = "support-attachments";
export const MAX_PHOTO_BYTES = 5_242_880;
export const MAX_ATTACHMENTS = 3;

export const attachmentFields = {
  mime_type: z.enum(["image/jpeg", "image/png", "image/webp"]),
  size_bytes: z.number().int().min(1).max(MAX_PHOTO_BYTES),
};

export const attachmentIds = z.array(z.string().uuid()).max(MAX_ATTACHMENTS);
