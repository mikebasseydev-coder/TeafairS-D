export interface OrdersApiClient {
  baseUrl: string;
}

export function createOrdersApiClient(baseUrl: string): OrdersApiClient {
  return { baseUrl };
}
