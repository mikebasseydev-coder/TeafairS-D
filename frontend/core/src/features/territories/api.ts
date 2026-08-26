export interface TerritoriesApiClient {
  baseUrl: string;
}

export function createTerritoriesApiClient(baseUrl: string): TerritoriesApiClient {
  return { baseUrl };
}
