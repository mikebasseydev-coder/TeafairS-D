import { createSupabaseClient } from './client';

describe('createSupabaseClient', () => {
  it('creates a client exposing the auth namespace', () => {
    const client = createSupabaseClient('https://example.supabase.co', 'anon-key');

    expect(client).toBeTruthy();
    expect(client.auth).toBeTruthy();
  });
});
