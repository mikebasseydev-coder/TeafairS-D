import { useEffect } from 'react';
import { getSession, useAuthStore } from '@teafair/core';
import { supabase } from './supabaseClient';

export function useAuthBootstrap() {
  const setSession = useAuthStore((state) => state.setSession);

  useEffect(() => {
    getSession(supabase).then(setSession);

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });

    return () => subscription.unsubscribe();
  }, [setSession]);
}
