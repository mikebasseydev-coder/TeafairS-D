import { Text, View } from 'react-native';
import { useAggregatorStore } from '@teafair/core';

export function AggregatorScreen() {
  const state = useAggregatorStore();

  return (
    <View>
      <Text>Aggregator</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
