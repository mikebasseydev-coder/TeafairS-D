export interface GamificationApiClient {
  baseUrl: string;
}

export function createGamificationApiClient(baseUrl: string): GamificationApiClient {
  return { baseUrl };
}
