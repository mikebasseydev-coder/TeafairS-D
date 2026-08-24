import type { SupabaseClient } from '@supabase/supabase-js';
import { unwrapSupabaseResult } from './unwrapSupabaseResult';

export interface Profile {
  id: string;
  username: string | null;
}

const DEFAULT_PROFILES_LIMIT = 50;

export async function fetchProfiles(
  client: SupabaseClient,
  limit: number = DEFAULT_PROFILES_LIMIT
): Promise<Profile[]> {
  const result = await client.from('profiles').select('id, username').limit(limit);

  return unwrapSupabaseResult<Profile[]>(result) ?? [];
}
