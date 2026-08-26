export interface AlertsApiClient {
  baseUrl: string;
}

export function createAlertsApiClient(baseUrl: string): AlertsApiClient {
  return { baseUrl };
}
