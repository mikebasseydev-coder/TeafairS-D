import { useAuthStore, createAuthApiClient } from './auth';
import { useCatalogStore, createCatalogApiClient } from './catalog';
import { useOrdersStore, createOrdersApiClient } from './orders';
import { useGamificationStore, createGamificationApiClient } from './gamification';
import { useAggregatorStore, createAggregatorApiClient } from './aggregator';

const features = [
  { name: 'auth', useStore: useAuthStore, createApiClient: createAuthApiClient },
  { name: 'catalog', useStore: useCatalogStore, createApiClient: createCatalogApiClient },
  { name: 'orders', useStore: useOrdersStore, createApiClient: createOrdersApiClient },
  { name: 'gamification', useStore: useGamificationStore, createApiClient: createGamificationApiClient },
  { name: 'aggregator', useStore: useAggregatorStore, createApiClient: createAggregatorApiClient },
];

describe.each(features)('$name feature module', ({ useStore, createApiClient }) => {
  it('exposes an empty Zustand store', () => {
    expect(useStore.getState()).toEqual({});
  });

  it('creates an API client carrying the base URL', () => {
    const client = createApiClient('https://api.teafair.dev');
    expect(client.baseUrl).toBe('https://api.teafair.dev');
  });
});
