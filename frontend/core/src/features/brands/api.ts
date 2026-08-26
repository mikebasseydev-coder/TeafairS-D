export interface BrandsApiClient {
  baseUrl: string;
}

export function createBrandsApiClient(baseUrl: string): BrandsApiClient {
  return { baseUrl };
}
