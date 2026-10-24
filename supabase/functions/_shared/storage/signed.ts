// Addendum A5 §4 — Storage REST calls with the service-role key. This is the
// only place the service key is used for Storage; paths and signed URLs are
// never logged and never put in an error message.
import { requireEnv } from "../core/env.ts";

export type StorageConfig = { url: string; serviceKey: string; fetch?: typeof globalThis.fetch };

export function storageConfigFromEnv(): StorageConfig {
  return { url: requireEnv("SUPABASE_URL"), serviceKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY") };
}

const base = (cfg: StorageConfig) => `${cfg.url.replace(/\/+$/, "")}/storage/v1`;
const encodePath = (path: string) => path.split("/").map(encodeURIComponent).join("/");

async function call(cfg: StorageConfig, method: string, endpoint: string, body?: unknown): Promise<unknown> {
  const res = await (cfg.fetch ?? fetch)(`${base(cfg)}${endpoint}`, {
    method,
    headers: {
      authorization: `Bearer ${cfg.serviceKey}`,
      apikey: cfg.serviceKey,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`storage ${method} failed with ${res.status}`);
  }
  return await res.json().catch(() => null);
}

function absolute(cfg: StorageConfig, relative: unknown): string {
  if (typeof relative !== "string" || relative.length === 0) throw new Error("storage returned no URL");
  if (/^https?:\/\//.test(relative)) return relative;
  return relative.startsWith("/storage/v1/")
    ? `${cfg.url.replace(/\/+$/, "")}${relative}`
    : `${base(cfg)}${relative.startsWith("/") ? "" : "/"}${relative}`;
}

// No x-upsert header: a claimed photo can never be overwritten through its URL.
export async function createSignedUploadUrl(cfg: StorageConfig, bucket: string, path: string): Promise<string> {
  const r = await call(cfg, "POST", `/object/upload/sign/${bucket}/${encodePath(path)}`) as { url?: string } | null;
  return absolute(cfg, r?.url);
}

export async function createSignedDownloadUrl(
  cfg: StorageConfig,
  bucket: string,
  path: string,
  expiresIn = 600,
): Promise<string> {
  const r = await call(cfg, "POST", `/object/sign/${bucket}/${encodePath(path)}`, { expiresIn }) as
    | { signedURL?: string }
    | null;
  return absolute(cfg, r?.signedURL);
}

// Storage answers 200 with the objects it removed; a missing object is simply
// absent from that list, so a 2xx means every requested path is gone.
export async function removeObjects(cfg: StorageConfig, bucket: string, paths: string[]): Promise<void> {
  await call(cfg, "DELETE", `/object/${bucket}`, { prefixes: paths });
}
