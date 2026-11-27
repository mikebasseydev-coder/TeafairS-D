// The one Supabase client. It holds only the URL and the publishable key
// (Ruling 46, Spec B §4.4); every call carries the user's JWT.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { secureAuthStorage } from "@/shared/storage/secure";
import type { Database } from "./database.types";

let client: SupabaseClient<Database> | null = null;

export function supabase(): SupabaseClient<Database> {
  if (client) return client;
  const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
  const key = process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) throw new Error("EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY must be set");
  client = createClient<Database>(url, key, {
    auth: { storage: secureAuthStorage, autoRefreshToken: true, persistSession: true, detectSessionInUrl: false },
  });
  return client;
}

/** Test-only: inject a client. */
export function __setSupabaseForTest(c: SupabaseClient<Database> | null): void {
  client = c;
}
