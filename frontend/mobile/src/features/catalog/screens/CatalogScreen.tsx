import { Text, View } from 'react-native';
import { useCatalogStore } from '@teafair/core';

export function CatalogScreen() {
  const state = useCatalogStore();

  return (
    <View>
      <Text>Catalog</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
