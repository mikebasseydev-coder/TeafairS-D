export interface ProductsApiClient {
  baseUrl: string;
}

export function createProductsApiClient(baseUrl: string): ProductsApiClient {
  return { baseUrl };
}
