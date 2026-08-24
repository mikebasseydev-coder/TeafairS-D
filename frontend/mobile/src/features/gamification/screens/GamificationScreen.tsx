import { Text, View } from 'react-native';
import { useGamificationStore } from '@teafair/core';

export function GamificationScreen() {
  const state = useGamificationStore();

  return (
    <View>
      <Text>Gamification</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
