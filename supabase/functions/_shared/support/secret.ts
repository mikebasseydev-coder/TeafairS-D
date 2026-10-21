// Addendum A3 §4 — the ticket secret is a bearer capability. It is
// HMAC-SHA256(server key, idempotency key), base64url with no padding (43
// characters), so a retried open (same idempotency key) returns the same
// secret the first, possibly lost, reply carried. The server key is
// SUPPORT_TICKET_SECRET_KEY, used as UTF-8 bytes. Only the secret's SHA-256
// hex is stored.
export async function ticketSecretFor(serverKey: string, idempotencyKey: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(serverKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(idempotencyKey)));
  return btoa(String.fromCharCode(...mac)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
