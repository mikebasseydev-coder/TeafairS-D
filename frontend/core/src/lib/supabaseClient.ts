import { createClient, type SupabaseClient, type SupabaseClientOptions } from '@supabase/supabase-js';

export type { SupabaseClient };

export function createSupabaseClient(
  url: string,
  anonKey: string,
  options?: SupabaseClientOptions<'public'>
): SupabaseClient {
  return createClient(url, anonKey, options);
}
