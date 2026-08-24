import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export type { SupabaseClient };

export function createSupabaseClient(url: string, anonKey: string): SupabaseClient {
  return createClient(url, anonKey);
}
