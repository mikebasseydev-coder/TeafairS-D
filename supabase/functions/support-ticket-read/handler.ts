// Addendum A3 §4 — read a conversation. (public_reference, secret) is the
// capability; any miss is the same 404.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { ATTACHMENT_BUCKET } from "../_shared/storage/attachment.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({
  public_reference: z.string().trim().toUpperCase().regex(/^TK-[0-9A-HJKMNP-TV-Z]{6}$/),
  secret: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
});

export type SupportTicketReadDeps = PublicGatewayDeps & {
  signDownload: (bucket: string, path: string) => Promise<string>;
};

type Attachment = { attachment_id: string; mime_type: string; storage_path: string };

// The database returns storage paths; the response carries only signed URLs (download links last 600 s).
async function signAttachments(ticket: unknown, deps: SupportTicketReadDeps): Promise<unknown> {
  const messages = (ticket as { messages?: unknown }).messages;
  if (!Array.isArray(messages)) return ticket;
  const signed = await Promise.all(messages.map(async (m: { attachments?: Attachment[] }) => {
    if (!Array.isArray(m.attachments)) return m;
    const attachments = await Promise.all(m.attachments.map(async (a) => {
      let url: string | null = null;
      try {
        url = await deps.signDownload(ATTACHMENT_BUCKET, a.storage_path);
      } catch {
        // a purged, never-uploaded or briefly unavailable photo must not fail the read; nothing is logged
      }
      return { attachment_id: a.attachment_id, mime_type: a.mime_type, url };
    }));
    return { ...m, attachments };
  }));
  return { ...(ticket as object), messages: signed };
}

export function createSupportTicketReadHandler(deps: SupportTicketReadDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    const ticket = await rpc<unknown>("read_support_ticket", {
      p_public_reference: body.public_reference,
      p_secret: body.secret,
    });
    if (ticket === null || ticket === undefined) {
      throw new GatewayError(404, "NOT_FOUND", "We couldn't find that conversation.");
    }
    return await signAttachments(ticket, deps);
  }, deps);
}
