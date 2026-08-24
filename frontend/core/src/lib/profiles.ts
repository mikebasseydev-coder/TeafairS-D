import { supabase } from './supabaseClient';

export interface Profile {
  id: string;
  username: string | null;
}

export async function fetchProfiles(): Promise<Profile[]> {
  const { data, error } = await supabase.from('profiles').select('id, username');

  if (error) {
    throw error;
  }

  return data ?? [];
}
