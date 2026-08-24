export interface AggregatorApiClient {
  baseUrl: string;
}

export function createAggregatorApiClient(baseUrl: string): AggregatorApiClient {
  return { baseUrl };
}
