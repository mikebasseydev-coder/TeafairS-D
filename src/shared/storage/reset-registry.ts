// Every feature store registers its reset at module load (Spec B §5).
// "session" runs every "tenant" reset first, then its own.

export type ResetScope = "tenant" | "session";
type Reset = () => void | Promise<void>;

const registry: Record<ResetScope, Map<string, Reset>> = { tenant: new Map(), session: new Map() };

export function registerReset(scope: ResetScope, name: string, reset: Reset): void {
  registry[scope].set(name, reset);
}

export function registeredResets(scope: ResetScope): string[] {
  return [...registry[scope].keys()];
}

async function runScope(scope: ResetScope, failures: unknown[]): Promise<void> {
  for (const reset of registry[scope].values()) {
    try {
      await reset();
    } catch (e) {
      failures.push(e);
    }
  }
}

/** Runs every reset of the scope, even when one throws; throws afterwards if any did. */
export async function runResets(scope: ResetScope): Promise<void> {
  const failures: unknown[] = [];
  if (scope === "session") await runScope("tenant", failures);
  await runScope(scope, failures);
  if (failures.length) throw new AggregateError(failures, `${failures.length} reset(s) failed`);
}

/** Test-only: forget every registration. */
export function __clearResetsForTest(): void {
  registry.tenant.clear();
  registry.session.clear();
}
