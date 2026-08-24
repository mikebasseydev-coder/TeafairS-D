export interface SupabaseResult<T> {
  data: T | null;
  error: { message: string } | null;
}

export function unwrapSupabaseResult<T>(result: SupabaseResult<T>): T | null {
  if (result.error) {
    throw new Error(result.error.message);
  }

  return result.data;
}
