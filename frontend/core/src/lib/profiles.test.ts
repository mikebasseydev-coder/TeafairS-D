import type { SupabaseClient } from '@supabase/supabase-js';
import { fetchProfiles } from './profiles';

function createMockClient(response: { data: unknown; error: unknown }) {
  const limit = jest.fn().mockResolvedValue(response);
  const select = jest.fn().mockReturnValue({ limit });
  const from = jest.fn().mockReturnValue({ select });

  return { from, select, limit, client: { from } as unknown as SupabaseClient };
}

describe('fetchProfiles', () => {
  it('queries the profiles table for id and username', async () => {
    const { client, from, select } = createMockClient({
      data: [{ id: '1', username: 'alice' }],
      error: null,
    });

    const profiles = await fetchProfiles(client);

    expect(from).toHaveBeenCalledWith('profiles');
    expect(select).toHaveBeenCalledWith('id, username');
    expect(profiles).toEqual([{ id: '1', username: 'alice' }]);
  });

  it('applies a default limit of 50', async () => {
    const { client, limit } = createMockClient({ data: [], error: null });

    await fetchProfiles(client);

    expect(limit).toHaveBeenCalledWith(50);
  });

  it('applies a caller-supplied limit', async () => {
    const { client, limit } = createMockClient({ data: [], error: null });

    await fetchProfiles(client, 10);

    expect(limit).toHaveBeenCalledWith(10);
  });

  it('returns an empty array when data is null', async () => {
    const { client } = createMockClient({ data: null, error: null });

    const profiles = await fetchProfiles(client);

    expect(profiles).toEqual([]);
  });

  it('throws when Supabase returns an error', async () => {
    const { client } = createMockClient({ data: null, error: { message: 'query failed' } });

    await expect(fetchProfiles(client)).rejects.toThrow('query failed');
  });
});
