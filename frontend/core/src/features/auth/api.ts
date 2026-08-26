import type { Session, SupabaseClient, User } from '@supabase/supabase-js';
import { unwrapSupabaseResult } from '../../lib/unwrapSupabaseResult';

export interface AuthResult {
  user: User | null;
  session: Session | null;
}

export async function signUpWithEmail(
  client: SupabaseClient,
  email: string,
  password: string
): Promise<AuthResult> {
  const result = await client.auth.signUp({ email, password });
  return unwrapSupabaseResult<AuthResult>(result) ?? { user: null, session: null };
}

export async function signInWithEmail(
  client: SupabaseClient,
  email: string,
  password: string
): Promise<AuthResult> {
  const result = await client.auth.signInWithPassword({ email, password });
  return unwrapSupabaseResult<AuthResult>(result) ?? { user: null, session: null };
}

export async function signOut(client: SupabaseClient): Promise<void> {
  const { error } = await client.auth.signOut();
  if (error) throw new Error(error.message);
}

export async function getSession(client: SupabaseClient): Promise<Session | null> {
  const result = await client.auth.getSession();
  return unwrapSupabaseResult<{ session: Session | null }>(result)?.session ?? null;
}
