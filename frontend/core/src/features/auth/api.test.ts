import type { SupabaseClient } from '@supabase/supabase-js';
import { signUpWithEmail, signInWithEmail, signOut, getSession } from './api';

function createMockClient(overrides: {
  signUp?: jest.Mock;
  signInWithPassword?: jest.Mock;
  signOut?: jest.Mock;
  getSession?: jest.Mock;
}) {
  const auth = {
    signUp: overrides.signUp ?? jest.fn(),
    signInWithPassword: overrides.signInWithPassword ?? jest.fn(),
    signOut: overrides.signOut ?? jest.fn(),
    getSession: overrides.getSession ?? jest.fn(),
  };

  return { auth, client: { auth } as unknown as SupabaseClient };
}

describe('signUpWithEmail', () => {
  it('returns the user and session on success', async () => {
    const { client, auth } = createMockClient({
      signUp: jest.fn().mockResolvedValue({
        data: { user: { id: '1' }, session: { access_token: 'tok' } },
        error: null,
      }),
    });

    const result = await signUpWithEmail(client, 'a@b.com', 'pw123456');

    expect(auth.signUp).toHaveBeenCalledWith({ email: 'a@b.com', password: 'pw123456' });
    expect(result).toEqual({ user: { id: '1' }, session: { access_token: 'tok' } });
  });

  it('throws when Supabase returns an error', async () => {
    const { client } = createMockClient({
      signUp: jest.fn().mockResolvedValue({
        data: { user: null, session: null },
        error: { message: 'already registered' },
      }),
    });

    await expect(signUpWithEmail(client, 'a@b.com', 'pw123456')).rejects.toThrow('already registered');
  });
});

describe('signInWithEmail', () => {
  it('returns the user and session on success', async () => {
    const { client, auth } = createMockClient({
      signInWithPassword: jest.fn().mockResolvedValue({
        data: { user: { id: '1' }, session: { access_token: 'tok' } },
        error: null,
      }),
    });

    const result = await signInWithEmail(client, 'a@b.com', 'pw123456');

    expect(auth.signInWithPassword).toHaveBeenCalledWith({ email: 'a@b.com', password: 'pw123456' });
    expect(result).toEqual({ user: { id: '1' }, session: { access_token: 'tok' } });
  });

  it('throws when credentials are invalid', async () => {
    const { client } = createMockClient({
      signInWithPassword: jest.fn().mockResolvedValue({
        data: { user: null, session: null },
        error: { message: 'invalid credentials' },
      }),
    });

    await expect(signInWithEmail(client, 'a@b.com', 'wrong')).rejects.toThrow('invalid credentials');
  });
});

describe('signOut', () => {
  it('resolves without error on success', async () => {
    const { client } = createMockClient({ signOut: jest.fn().mockResolvedValue({ error: null }) });

    await expect(signOut(client)).resolves.toBeUndefined();
  });

  it('throws when Supabase returns an error', async () => {
    const { client } = createMockClient({
      signOut: jest.fn().mockResolvedValue({ error: { message: 'network error' } }),
    });

    await expect(signOut(client)).rejects.toThrow('network error');
  });
});

describe('getSession', () => {
  it('returns the current session', async () => {
    const { client } = createMockClient({
      getSession: jest.fn().mockResolvedValue({ data: { session: { access_token: 'tok' } }, error: null }),
    });

    await expect(getSession(client)).resolves.toEqual({ access_token: 'tok' });
  });

  it('returns null when there is no session', async () => {
    const { client } = createMockClient({
      getSession: jest.fn().mockResolvedValue({ data: { session: null }, error: null }),
    });

    await expect(getSession(client)).resolves.toBeNull();
  });
});
