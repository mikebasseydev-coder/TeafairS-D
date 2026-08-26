import { useState } from 'react';
import { Text, View } from 'react-native';
import { signInWithEmail, signOut, signUpWithEmail, useAuthStore } from '@teafair/core';
import { Button, InputField } from '../../../components';
import { supabase } from '../../../lib/supabaseClient';

export function AuthScreen() {
  const session = useAuthStore((state) => state.session);
  const setSession = useAuthStore((state) => state.setSession);
  const clearSession = useAuthStore((state) => state.clear);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  const canSubmit = email.trim().length > 0 && password.length > 0 && !isSubmitting;

  async function handleSignIn() {
    setIsSubmitting(true);
    setError(null);
    setInfo(null);
    try {
      const result = await signInWithEmail(supabase, email.trim(), password);
      setSession(result.session);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign-in failed.');
    } finally {
      setIsSubmitting(false);
    }
  }

  async function handleSignUp() {
    setIsSubmitting(true);
    setError(null);
    setInfo(null);
    try {
      const result = await signUpWithEmail(supabase, email.trim(), password);
      if (result.session) {
        setSession(result.session);
      } else {
        setInfo('Check your email to confirm your account before signing in.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign-up failed.');
    } finally {
      setIsSubmitting(false);
    }
  }

  async function handleSignOut() {
    setIsSubmitting(true);
    setError(null);
    try {
      await signOut(supabase);
      clearSession();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign-out failed.');
    } finally {
      setIsSubmitting(false);
    }
  }

  if (session) {
    return (
      <View className="flex-1 justify-center p-4">
        <Text className="mb-4">Signed in as {session.user.email}</Text>
        {error ? <Text className="mb-4 text-sm text-red-600">{error}</Text> : null}
        <Button label={isSubmitting ? 'Signing out…' : 'Sign out'} onPress={handleSignOut} disabled={isSubmitting} />
      </View>
    );
  }

  return (
    <View className="flex-1 justify-center p-4">
      <Text className="mb-4 text-xl font-semibold">Sign in</Text>
      <InputField
        label="Email"
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        keyboardType="email-address"
      />
      <InputField label="Password" value={password} onChangeText={setPassword} secureTextEntry />
      {error ? <Text className="mb-4 text-sm text-red-600">{error}</Text> : null}
      {info ? <Text className="mb-4 text-sm text-green-600">{info}</Text> : null}
      <View className="gap-3">
        <Button label={isSubmitting ? 'Signing in…' : 'Continue'} onPress={handleSignIn} disabled={!canSubmit} />
        <Button label="Create account" onPress={handleSignUp} disabled={!canSubmit} />
      </View>
    </View>
  );
}
