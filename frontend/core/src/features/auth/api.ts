export interface AuthApiClient {
  baseUrl: string;
}

export function createAuthApiClient(baseUrl: string): AuthApiClient {
  return { baseUrl };
}
