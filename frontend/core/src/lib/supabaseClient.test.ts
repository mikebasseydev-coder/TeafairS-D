import { createSupabaseClient } from './supabaseClient';

describe('createSupabaseClient', () => {
  it('builds a client exposing the Supabase query surface', () => {
    const client = createSupabaseClient('https://example.supabase.co', 'anon-key-123');

    expect(typeof client.from).toBe('function');
    expect(client.auth).toBeDefined();
  });

  it('returns an independent instance on every call (no shared singleton)', () => {
    const clientA = createSupabaseClient('https://a.supabase.co', 'key-a');
    const clientB = createSupabaseClient('https://b.supabase.co', 'key-b');

    expect(clientA).not.toBe(clientB);
  });
});
