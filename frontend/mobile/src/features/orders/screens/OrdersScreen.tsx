import { Text, View } from 'react-native';
import { useOrdersStore } from '@teafair/core';

export function OrdersScreen() {
  const state = useOrdersStore();

  return (
    <View>
      <Text>Orders</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
