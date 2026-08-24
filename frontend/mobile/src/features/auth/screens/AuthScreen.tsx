import { Text, View } from 'react-native';
import { useAuthStore } from '@teafair/core';

export function AuthScreen() {
  const state = useAuthStore();

  return (
    <View>
      <Text>Auth</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
