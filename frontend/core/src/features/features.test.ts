import { useCatalogStore, createCatalogApiClient } from './catalog';
import { useOrdersStore, createOrdersApiClient } from './orders';
import { useGamificationStore, createGamificationApiClient } from './gamification';
import { useAggregatorStore, createAggregatorApiClient } from './aggregator';
import { useProductsStore, createProductsApiClient } from './products';
import { useBrandsStore, createBrandsApiClient } from './brands';
import { useTerritoriesStore, createTerritoriesApiClient } from './territories';
import { useAlertsStore, createAlertsApiClient } from './alerts';

const features = [
  { name: 'catalog', useStore: useCatalogStore, createApiClient: createCatalogApiClient },
  { name: 'orders', useStore: useOrdersStore, createApiClient: createOrdersApiClient },
  { name: 'gamification', useStore: useGamificationStore, createApiClient: createGamificationApiClient },
  { name: 'aggregator', useStore: useAggregatorStore, createApiClient: createAggregatorApiClient },
  { name: 'products', useStore: useProductsStore, createApiClient: createProductsApiClient },
  { name: 'brands', useStore: useBrandsStore, createApiClient: createBrandsApiClient },
  { name: 'territories', useStore: useTerritoriesStore, createApiClient: createTerritoriesApiClient },
  { name: 'alerts', useStore: useAlertsStore, createApiClient: createAlertsApiClient },
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
