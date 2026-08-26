import type { Storage } from '@teafair/core';
import * as SecureStore from 'expo-secure-store';

export const secureStoreAdapter: Storage = {
  getItem: (key) => SecureStore.getItemAsync(key),
  setItem: (key, value) => SecureStore.setItemAsync(key, value),
  removeItem: (key) => SecureStore.deleteItemAsync(key),
};
