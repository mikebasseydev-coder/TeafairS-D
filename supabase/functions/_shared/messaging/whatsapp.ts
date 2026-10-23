// Meta WhatsApp Cloud API transport (addendum A5 §7). Template messages only.
// The access token is never put in an error message.
export type WhatsAppConfig = { token: string; phoneNumberId: string; apiVersion: string; apiUrl?: string };

export type WhatsAppTemplate = { name: string; language: string; params: string[] };

/** A non-2xx answer from Meta; `code` is Meta's `error.code` when present. */
export class WhatsAppError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message);
    this.name = "WhatsAppError";
  }
}

export function whatsAppConfigFromEnv(): WhatsAppConfig | null {
  const token = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const apiVersion = Deno.env.get("WHATSAPP_API_VERSION");
  if (!token || !phoneNumberId || !apiVersion) return null;
  return { token, phoneNumberId, apiVersion, apiUrl: Deno.env.get("WHATSAPP_API_URL") || undefined };
}

export async function sendWhatsAppTemplate(
  cfg: WhatsAppConfig,
  to: string,
  template: WhatsAppTemplate,
  signal: AbortSignal,
  fetchFn: typeof fetch = fetch,
): Promise<void> {
  const base = (cfg.apiUrl ?? "https://graph.facebook.com").replace(/\/$/, "");
  const res = await fetchFn(`${base}/${cfg.apiVersion}/${cfg.phoneNumberId}/messages`, {
    method: "POST",
    signal,
    headers: { Authorization: `Bearer ${cfg.token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to: to.replace(/^\+/, ""),
      type: "template",
      template: {
        name: template.name,
        language: { code: template.language },
        // authentication templates also carry the code on their copy-code button
        components: [
          { type: "body", parameters: template.params.map((text) => ({ type: "text", text })) },
          ...(template.name.includes("otp")
            ? [{ type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: template.params[0] ?? "" }] }]
            : []),
        ],
      },
    }),
  });
  if (res.ok) {
    await res.body?.cancel();
    return;
  }
  const payload = await res.json().catch(() => null) as { error?: { code?: number | string } } | null;
  const code = payload?.error?.code === undefined ? undefined : String(payload.error.code);
  throw new WhatsAppError(`WhatsApp send failed: HTTP ${res.status}${code ? ` (code ${code})` : ""}`, code);
}
