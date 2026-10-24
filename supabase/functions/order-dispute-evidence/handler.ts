// Addendum A5 §6 — the ZSM's dispute evidence bundle. The database returns
// storage paths; this gateway signs each one for 10 minutes and the response
// carries only the URLs, never a path or bucket.
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";

const schema = z.object({ order_id: z.string().uuid() });

export type OrderDisputeEvidenceDeps = UserGatewayDeps & {
  signDownload: (bucket: string, path: string) => Promise<string>;
};

type Stored = { bucket: string; storage_path: string };
type Attachment = Stored & { attachment_id: string; mime_type: string; size_bytes: number };
type Message = { attachments?: Attachment[] } & Record<string, unknown>;
type Ticket = { messages?: Message[] } & Record<string, unknown>;
type Bundle = {
  fulfilment?: ({ delivery_photo?: Stored | null } & Record<string, unknown>) | null;
  tickets?: Ticket[];
} & Record<string, unknown>;

// a purged, never-uploaded or briefly unavailable photo must not fail the read; nothing is logged
async function sign(deps: OrderDisputeEvidenceDeps, s: Stored): Promise<string | null> {
  try {
    return await deps.signDownload(s.bucket, s.storage_path);
  } catch {
    return null;
  }
}

async function signBundle(bundle: Bundle, deps: OrderDisputeEvidenceDeps): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = { ...bundle };
  if (bundle.fulfilment && bundle.fulfilment.delivery_photo) {
    out.fulfilment = {
      ...bundle.fulfilment,
      delivery_photo: { url: await sign(deps, bundle.fulfilment.delivery_photo) },
    };
  }
  if (Array.isArray(bundle.tickets)) {
    out.tickets = await Promise.all(bundle.tickets.map(async (t) => {
      if (!Array.isArray(t.messages)) return t;
      const messages = await Promise.all(t.messages.map(async (m) => {
        if (!Array.isArray(m.attachments)) return m;
        const attachments = await Promise.all(m.attachments.map(async (a) => ({
          attachment_id: a.attachment_id,
          mime_type: a.mime_type,
          size_bytes: a.size_bytes,
          url: await sign(deps, a),
        })));
        return { ...m, attachments };
      }));
      return { ...t, messages };
    }));
  }
  return out;
}

export function createOrderDisputeEvidenceHandler(deps: OrderDisputeEvidenceDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const bundle = await rpc<Bundle>("get_order_dispute_evidence", { p_order_id: body.order_id });
    return await signBundle(bundle, deps);
  }, deps);
}
