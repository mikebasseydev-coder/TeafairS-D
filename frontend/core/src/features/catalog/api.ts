export interface CatalogApiClient {
  baseUrl: string;
}

export function createCatalogApiClient(baseUrl: string): CatalogApiClient {
  return { baseUrl };
}
