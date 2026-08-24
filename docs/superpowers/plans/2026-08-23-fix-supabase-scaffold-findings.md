# Fix Supabase Scaffold Code Review Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 10 findings from the `/code-review` of the Supabase/NativeWind scaffold work (commit `6f4da8d`) without regressing the working AuthScreen/InputField/Button UI.

**Architecture:** Restore `core`'s Supabase client to an injectable factory (matching the `create<X>ApiClient(baseUrl)` convention every other feature module already uses) instead of an eager, env-reading singleton. Move the actual `process.env.EXPO_PUBLIC_*` reads back into the `mobile` app (its own source root, not the shared workspace package), matching where the deleted `mobile/src/supabase.ts` used to do it. Thread the client into `fetchProfiles` as a parameter instead of importing a module-level singleton, and extract the repeated Supabase error-unwrap into one shared helper. Separately, fix two small UI bugs (`InputField` className clobbering, `AuthScreen`'s unmarked no-op button).

**Tech Stack:** TypeScript, `@supabase/supabase-js` v2, Zustand, Jest + ts-jest (core package only — `mobile` has no test runner configured), Expo/React Native, NativeWind.

**Spec:** `docs/superpowers/specs/2026-08-23-frontend-scaffold-design.md`

## Global Constraints

- Core package must have zero React Native / Expo / platform-specific imports or env reads — enforced by convention, no native/Expo deps in `core/package.json` (spec lines 60-61).
- All work happens inside the existing `frontend-monorepo-scaffold` worktree at `C:\Users\User\Teafair\.claude\worktrees\frontend-monorepo-scaffold\frontend` — all file paths below are relative to that `frontend/` directory.
- `core` uses Jest + ts-jest (`core/jest.config.js`); run tests with `npx jest` from `frontend/core`. `mobile` has no test runner — its tasks are verified with `npx tsc --noEmit` instead.
- Every exported function that touches Supabase must take the client as a parameter — no module-level client singletons inside `core`.

---

### Task 1: Rewrite core's Supabase client as an injectable factory

**Files:**
- Modify: `core/src/lib/supabaseClient.ts`
- Test: `core/src/lib/supabaseClient.test.ts`
- Create: `core/.gitignore`

**Interfaces:**
- Produces: `createSupabaseClient(url: string, anonKey: string): SupabaseClient` — used by Task 3 (`mobile/src/lib/supabaseClient.ts`) and by Task 2's tests.

- [ ] **Step 1: Write the failing test**

Create `core/src/lib/supabaseClient.test.ts`:

```typescript
import { createSupabaseClient } from './supabaseClient';

describe('createSupabaseClient', () => {
  it('builds a client exposing the Supabase query surface', () => {
    const client = createSupabaseClient('https://example.supabase.co', 'anon-key-123');

    expect(typeof client.from).toBe('function');
    expect(client.auth).toBeDefined();
  });

  it('returns an independent instance on every call (no shared singleton)', () => {
    const clientA = createSupabaseClient('https://a.supabase.co', 'key-a');
    const clientB = createSupabaseClient('https://b.supabase.co', 'key-b');

    expect(clientA).not.toBe(clientB);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `frontend/core`): `npx jest src/lib/supabaseClient.test.ts`
Expected: FAIL — `createSupabaseClient` is not exported (current file only exports a `supabase` singleton).

- [ ] **Step 3: Replace the eager singleton with a factory, and stop reading `process.env`**

Replace the full contents of `core/src/lib/supabaseClient.ts` with:

```typescript
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export type { SupabaseClient };

export function createSupabaseClient(url: string, anonKey: string): SupabaseClient {
  return createClient(url, anonKey);
}
```

This removes the `process.env.EXPO_PUBLIC_*` reads and the module-load-time `throw` entirely — nothing in `core` executes at import time anymore, so `export * from './lib/supabaseClient'` in `core/src/index.ts` (unchanged) can no longer crash a consumer that only wants `useAuthStore` or any other unrelated export.

- [ ] **Step 4: Run test to verify it passes**

Run (from `frontend/core`): `npx jest src/lib/supabaseClient.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Add a `.gitignore` for `core`'s own `.env` files**

Create `core/.gitignore`:

```
node_modules/
dist/
*.tsbuildinfo

# local env files
.env
.env*.local
```

`core` no longer reads env vars itself (Step 3), but this closes the gap the review flagged: nothing currently excludes a `core/.env` from git if one gets added later, unlike `mobile/.gitignore` which already covers it.

- [ ] **Step 6: Commit**

```bash
git add core/src/lib/supabaseClient.ts core/src/lib/supabaseClient.test.ts core/.gitignore
git commit -m "fix(core): make Supabase client an injectable factory, drop env reads"
```

---

### Task 2: Extract shared Supabase result helper; make `fetchProfiles` injectable and paginated

**Files:**
- Create: `core/src/lib/unwrapSupabaseResult.ts`
- Test: `core/src/lib/unwrapSupabaseResult.test.ts`
- Modify: `core/src/lib/profiles.ts`
- Test: `core/src/lib/profiles.test.ts`

**Interfaces:**
- Consumes: nothing from Task 1 directly (only the `SupabaseClient` type, imported from `@supabase/supabase-js`).
- Produces: `unwrapSupabaseResult<T>(result: { data: T | null; error: { message: string } | null }): T | null`, and `fetchProfiles(client: SupabaseClient, limit?: number): Promise<Profile[]>` — the new signature Task 3's mobile code (if it ever calls this) and any future consumer must use.

- [ ] **Step 1: Write the failing test for the helper**

Create `core/src/lib/unwrapSupabaseResult.ts` test first — `core/src/lib/unwrapSupabaseResult.test.ts`:

```typescript
import { unwrapSupabaseResult } from './unwrapSupabaseResult';

describe('unwrapSupabaseResult', () => {
  it('returns data when there is no error', () => {
    const result = unwrapSupabaseResult({ data: [{ id: '1' }], error: null });

    expect(result).toEqual([{ id: '1' }]);
  });

  it('throws an Error carrying the Supabase error message when present', () => {
    expect(() =>
      unwrapSupabaseResult({ data: null, error: { message: 'boom' } })
    ).toThrow('boom');
  });

  it('returns null data as-is when there is no error', () => {
    const result = unwrapSupabaseResult({ data: null, error: null });

    expect(result).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `frontend/core`): `npx jest src/lib/unwrapSupabaseResult.test.ts`
Expected: FAIL — cannot find module `./unwrapSupabaseResult`.

- [ ] **Step 3: Implement the helper**

Create `core/src/lib/unwrapSupabaseResult.ts`:

```typescript
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
```

- [ ] **Step 4: Run test to verify it passes**

Run (from `frontend/core`): `npx jest src/lib/unwrapSupabaseResult.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Write the failing tests for `fetchProfiles`**

Replace the full contents of `core/src/lib/profiles.test.ts` (new file):

```typescript
import type { SupabaseClient } from '@supabase/supabase-js';
import { fetchProfiles } from './profiles';

function createMockClient(response: { data: unknown; error: unknown }) {
  const limit = jest.fn().mockResolvedValue(response);
  const select = jest.fn().mockReturnValue({ limit });
  const from = jest.fn().mockReturnValue({ select });

  return { from, select, limit, client: { from } as unknown as SupabaseClient };
}

describe('fetchProfiles', () => {
  it('queries the profiles table for id and username', async () => {
    const { client, from, select } = createMockClient({
      data: [{ id: '1', username: 'alice' }],
      error: null,
    });

    const profiles = await fetchProfiles(client);

    expect(from).toHaveBeenCalledWith('profiles');
    expect(select).toHaveBeenCalledWith('id, username');
    expect(profiles).toEqual([{ id: '1', username: 'alice' }]);
  });

  it('applies a default limit of 50', async () => {
    const { client, limit } = createMockClient({ data: [], error: null });

    await fetchProfiles(client);

    expect(limit).toHaveBeenCalledWith(50);
  });

  it('applies a caller-supplied limit', async () => {
    const { client, limit } = createMockClient({ data: [], error: null });

    await fetchProfiles(client, 10);

    expect(limit).toHaveBeenCalledWith(10);
  });

  it('returns an empty array when data is null', async () => {
    const { client } = createMockClient({ data: null, error: null });

    const profiles = await fetchProfiles(client);

    expect(profiles).toEqual([]);
  });

  it('throws when Supabase returns an error', async () => {
    const { client } = createMockClient({ data: null, error: { message: 'query failed' } });

    await expect(fetchProfiles(client)).rejects.toThrow('query failed');
  });
});
```

- [ ] **Step 6: Run tests to verify they fail**

Run (from `frontend/core`): `npx jest src/lib/profiles.test.ts`
Expected: FAIL — `fetchProfiles` still imports the deleted `supabase` singleton and takes no `client` parameter.

- [ ] **Step 7: Implement the injectable, paginated `fetchProfiles`**

Replace the full contents of `core/src/lib/profiles.ts`:

```typescript
import type { SupabaseClient } from '@supabase/supabase-js';
import { unwrapSupabaseResult } from './unwrapSupabaseResult';

export interface Profile {
  id: string;
  username: string | null;
}

const DEFAULT_PROFILES_LIMIT = 50;

export async function fetchProfiles(
  client: SupabaseClient,
  limit: number = DEFAULT_PROFILES_LIMIT
): Promise<Profile[]> {
  const result = await client.from('profiles').select('id, username').limit(limit);

  return unwrapSupabaseResult<Profile[]>(result) ?? [];
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run (from `frontend/core`): `npx jest src/lib/profiles.test.ts`
Expected: PASS (5 tests)

- [ ] **Step 9: Run the full core test suite**

Run (from `frontend/core`): `npx jest`
Expected: PASS — includes `features.test.ts`, `storage/types.test.ts`, and the three new/modified files above.

- [ ] **Step 10: Commit**

```bash
git add core/src/lib/unwrapSupabaseResult.ts core/src/lib/unwrapSupabaseResult.test.ts core/src/lib/profiles.ts core/src/lib/profiles.test.ts
git commit -m "fix(core): inject Supabase client into fetchProfiles, add pagination and shared result unwrap"
```

---

### Task 3: Restore the mobile-side Supabase client (env vars read in app source, not in `core`)

**Files:**
- Create: `mobile/src/lib/supabaseClient.ts`

**Interfaces:**
- Consumes: `createSupabaseClient(url: string, anonKey: string): SupabaseClient` from `@teafair/core` (Task 1).
- Produces: `supabase: SupabaseClient` — the app-wide singleton instance, for any mobile screen that needs to call Supabase directly or pass a client into `fetchProfiles`.

- [ ] **Step 1: Create the file**

Create `mobile/src/lib/supabaseClient.ts`:

```typescript
import { createSupabaseClient } from '@teafair/core';

const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Missing Supabase environment variables: EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_ANON_KEY must be set.'
  );
}

export const supabase = createSupabaseClient(supabaseUrl, supabaseAnonKey);
```

This is the same shape as the `mobile/src/supabase.ts` that commit `6f4da8d` deleted — restored under `src/lib/` for consistency with `core/src/lib/`. Because this file lives inside `mobile`'s own source root (not the `@teafair/core` workspace package resolved through `node_modules`), Metro/Babel's `EXPO_PUBLIC_*` env-inlining transform applies to it the same way it already applies to every other file directly under `mobile/src`. No `metro.config.js` change is needed.

Nothing in `mobile` currently imports this file (confirmed: only `AuthScreen.tsx` uses `@teafair/core`, and only for `useAuthStore`) — it exists as the entry point the next screen that needs Supabase (e.g. wiring up `fetchProfiles`) will import from.

- [ ] **Step 2: Typecheck**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add mobile/src/lib/supabaseClient.ts
git commit -m "fix(mobile): restore app-side Supabase client, reading env vars in mobile source"
```

---

### Task 4: Fix `InputField` overwriting caller-supplied `className` instead of merging it

**Files:**
- Modify: `mobile/src/components/InputField.tsx`

- [ ] **Step 1: Destructure `className` and merge it with the default styles**

Replace the full contents of `mobile/src/components/InputField.tsx`:

```tsx
import { Text, TextInput, View } from 'react-native';
import type { TextInputProps } from 'react-native';

interface InputFieldProps extends TextInputProps {
  label: string;
}

export function InputField({ label, className, ...textInputProps }: InputFieldProps) {
  return (
    <View className="mb-4">
      <Text className="mb-1 text-sm font-medium text-gray-700">{label}</Text>
      <TextInput
        className={`rounded-md border border-gray-300 px-3 py-2 text-base ${className ?? ''}`}
        {...textInputProps}
      />
    </View>
  );
}
```

Pulling `className` out of `textInputProps` before the spread means it's no longer applied twice (once via spread, once via the explicit prop) — it's merged into one string instead of the spread silently replacing the default.

- [ ] **Step 2: Typecheck**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no errors. (No test runner is configured for `mobile` — this is the same verification method the existing `AuthScreen.tsx` usage relies on today.)

- [ ] **Step 3: Commit**

```bash
git add mobile/src/components/InputField.tsx
git commit -m "fix(mobile): merge caller className into InputField instead of overwriting it"
```

---

### Task 5: Mark `AuthScreen`'s unwired Continue button as disabled, not silently no-op

**Files:**
- Modify: `mobile/src/features/auth/screens/AuthScreen.tsx`

- [ ] **Step 1: Disable the button until sign-in submission is implemented**

Replace the full contents of `mobile/src/features/auth/screens/AuthScreen.tsx`:

```tsx
import { useState } from 'react';
import { Text, View } from 'react-native';
import { useAuthStore } from '@teafair/core';
import { Button, InputField } from '../../../components';

export function AuthScreen() {
  const state = useAuthStore();
  const [email, setEmail] = useState('');

  return (
    <View className="flex-1 justify-center p-4">
      <Text>Auth</Text>
      <Text>{JSON.stringify(state)}</Text>
      <InputField label="Email" value={email} onChangeText={setEmail} />
      {/* Sign-in submission isn't implemented yet. */}
      <Button label="Continue" onPress={() => {}} disabled />
    </View>
  );
}
```

`Button` already renders a visually distinct disabled state (gray background instead of blue — see `mobile/src/components/Button.tsx:14-16`), so this makes the incomplete state visible in the UI instead of only in a code comment.

- [ ] **Step 2: Typecheck**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add mobile/src/features/auth/screens/AuthScreen.tsx
git commit -m "fix(mobile): disable AuthScreen's Continue button until sign-in is wired up"
```

---

## Final Verification

- [ ] Run `npx jest` from `frontend/core` — all tests pass.
- [ ] Run `npx tsc --noEmit` from `frontend/core` — no errors.
- [ ] Run `npx tsc --noEmit` from `frontend/mobile` — no errors.
- [ ] Confirm no remaining references to the deleted `core/src/supabase/` path: `grep -r "from '.*supabase/client'" frontend/` returns nothing.
- [ ] Confirm `core/src/index.ts` still exports `createSupabaseClient` (via `export * from './lib/supabaseClient'`) and no longer exports a `supabase` singleton.
