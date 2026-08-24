import { unwrapSupabaseResult } from './unwrapSupabaseResult';

describe('unwrapSupabaseResult', () => {
  it('returns data when there is no error', () => {
    const result = unwrapSupabaseResult({ data: [{ id: '1' }], error: null });

    expect(result).toEqual([{ id: '1' }]);
  });

  it('throws an Error carrying the Supabase error message when present', () => {
    expect(() =>
      unwrapSupabaseResult({ data: null, error: { message: 'boom' } })
    ).toThrow('boom');
  });

  it('returns null data as-is when there is no error', () => {
    const result = unwrapSupabaseResult({ data: null, error: null });

    expect(result).toBeNull();
  });
});
