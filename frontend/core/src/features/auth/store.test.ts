import type { Session } from '@supabase/supabase-js';
import { useAuthStore } from './store';

function mockSession(userId: string): Session {
  return { access_token: 'tok', user: { id: userId } } as unknown as Session;
}

describe('useAuthStore', () => {
  afterEach(() => {
    useAuthStore.getState().clear();
  });

  it('starts with no session or user', () => {
    expect(useAuthStore.getState().session).toBeNull();
    expect(useAuthStore.getState().user).toBeNull();
  });

  it('setSession stores the session and derives the user from it', () => {
    const session = mockSession('1');

    useAuthStore.getState().setSession(session);

    expect(useAuthStore.getState().session).toBe(session);
    expect(useAuthStore.getState().user).toEqual({ id: '1' });
  });

  it('setSession(null) clears the user too', () => {
    useAuthStore.getState().setSession(mockSession('1'));

    useAuthStore.getState().setSession(null);

    expect(useAuthStore.getState().session).toBeNull();
    expect(useAuthStore.getState().user).toBeNull();
  });

  it('clear resets session and user to null', () => {
    useAuthStore.getState().setSession(mockSession('1'));

    useAuthStore.getState().clear();

    expect(useAuthStore.getState().session).toBeNull();
    expect(useAuthStore.getState().user).toBeNull();
  });
});
