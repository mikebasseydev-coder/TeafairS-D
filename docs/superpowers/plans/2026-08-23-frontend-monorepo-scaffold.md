# Teafair Frontend Monorepo Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold `frontend/` as an npm-workspaces monorepo (`core`, `mobile`, `windows`) with a shared platform-agnostic logic package, an Expo Android app that builds and runs a dev-client build on a connected device, and a scaffolded (not build-validated) `react-native-windows` app.

**Architecture:** `core` holds Zustand stores, API client shells, and a `Storage` interface — zero `react-native`/`expo` imports. `mobile` (Expo + expo-dev-client) and `windows` (bare RN + react-native-windows) each depend on `core` via npm workspace linking, and each supplies its own UI (React Navigation, native primitives only) and its own `Storage` adapter (`expo-secure-store` for mobile, `@react-native-async-storage/async-storage` for windows).

**Tech Stack:** TypeScript, npm workspaces, Zustand, React Navigation (native-stack + bottom-tabs), NativeWind (mobile only), Jest/ts-jest (core only), Expo SDK (mobile), react-native-windows (windows).

**Spec:** `docs/superpowers/specs/2026-08-23-frontend-scaffold-design.md`

## Global Constraints

- Package manager is npm only — never yarn or pnpm.
- All code is TypeScript.
- `core` must never import `react-native`, `expo`, or any platform-specific package — it is consumed by both a mobile and a desktop target.
- No `react-native-web`. UI code uses only native RN primitives (`View`, `Text`, `Pressable`, etc.) — never `<div>`, `<h1>`, or other HTML tags.
- Android app identity is `com.teafair.app`.
- The `windows` app is scaffolded and type-checked only — `react-native run-windows` / any native Windows build is explicitly NOT attempted (Visual Studio C++/UWP workloads are not installed in this environment).
- No real business logic (auth, catalog, orders, payouts, gamification, aggregator) — stores and screens are structural placeholders only.
- No component/UI test framework is installed this phase — mobile and windows tasks are validated via TypeScript compilation and, where the task says so, a manual device run. This mirrors the spec's own "Validation" section.
- Working directory for npm/expo/RN commands is `frontend/` (the workspaces root) unless a step says otherwise. Working directory for `git` commands is the repo root (`C:\Users\User\Teafair`).

---

## Task 1: Workspace root + core package's Storage interface

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/core/package.json`
- Create: `frontend/core/tsconfig.json`
- Create: `frontend/core/jest.config.js`
- Test: `frontend/core/src/storage/types.test.ts`
- Create: `frontend/core/src/storage/types.ts`
- Create: `frontend/core/src/index.ts`

**Interfaces:**
- Produces: `Storage` interface (`getItem(key: string): Promise<string | null>`, `setItem(key: string, value: string): Promise<void>`, `removeItem(key: string): Promise<void>`) exported from `@teafair/core`.

- [ ] **Step 1: Create the workspace root package.json**

`frontend/package.json`:
```json
{
  "name": "teafair-frontend",
  "private": true,
  "workspaces": [
    "core"
  ]
}
```

- [ ] **Step 2: Create the core package manifest, tsconfig, and jest config**

`frontend/core/package.json`:
```json
{
  "name": "@teafair/core",
  "version": "0.1.0",
  "private": true,
  "main": "src/index.ts",
  "types": "src/index.ts",
  "scripts": {
    "test": "jest",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "zustand": "^4.5.2"
  },
  "devDependencies": {
    "@types/jest": "^29.5.12",
    "jest": "^29.7.0",
    "ts-jest": "^29.1.2",
    "typescript": "^5.4.5"
  }
}
```

`frontend/core/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"]
}
```

`frontend/core/jest.config.js`:
```js
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
};
```

- [ ] **Step 3: Install dependencies**

Run (from `frontend/`): `npm install`
Expected: installs `zustand`, `jest`, `ts-jest`, `typescript`, `@types/jest` into `frontend/node_modules`, creates `frontend/package-lock.json`, no errors.

- [ ] **Step 4: Write the failing test**

`frontend/core/src/storage/types.test.ts`:
```ts
import { Storage } from './types';

class MemoryStorage implements Storage {
  private data = new Map<string, string>();

  async getItem(key: string): Promise<string | null> {
    return this.data.has(key) ? this.data.get(key)! : null;
  }

  async setItem(key: string, value: string): Promise<void> {
    this.data.set(key, value);
  }

  async removeItem(key: string): Promise<void> {
    this.data.delete(key);
  }
}

describe('Storage interface', () => {
  it('round-trips a value through set/get/remove', async () => {
    const storage: Storage = new MemoryStorage();

    expect(await storage.getItem('token')).toBeNull();

    await storage.setItem('token', 'abc123');
    expect(await storage.getItem('token')).toBe('abc123');

    await storage.removeItem('token');
    expect(await storage.getItem('token')).toBeNull();
  });
});
```

- [ ] **Step 5: Run the test and verify it fails**

Run (from `frontend/core`): `npx jest`
Expected: FAIL — `Cannot find module './types' from 'src/storage/types.test.ts'`

- [ ] **Step 6: Implement the Storage interface**

`frontend/core/src/storage/types.ts`:
```ts
export interface Storage {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}
```

- [ ] **Step 7: Run the test and verify it passes**

Run (from `frontend/core`): `npx jest`
Expected: PASS — 1 test passed.

- [ ] **Step 8: Create the core barrel export**

`frontend/core/src/index.ts`:
```ts
export * from './storage/types';
```

- [ ] **Step 9: Typecheck**

Run (from `frontend/core`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 10: Commit**

```bash
git add frontend/package.json frontend/core
git commit -m "Add frontend workspace root and core package Storage interface"
```

---

## Task 2: Core feature module shells (auth, catalog, orders, gamification, aggregator)

**Files:**
- Test: `frontend/core/src/features/features.test.ts`
- Create: `frontend/core/src/features/auth/store.ts`
- Create: `frontend/core/src/features/auth/api.ts`
- Create: `frontend/core/src/features/auth/index.ts`
- Create: `frontend/core/src/features/catalog/store.ts`
- Create: `frontend/core/src/features/catalog/api.ts`
- Create: `frontend/core/src/features/catalog/index.ts`
- Create: `frontend/core/src/features/orders/store.ts`
- Create: `frontend/core/src/features/orders/api.ts`
- Create: `frontend/core/src/features/orders/index.ts`
- Create: `frontend/core/src/features/gamification/store.ts`
- Create: `frontend/core/src/features/gamification/api.ts`
- Create: `frontend/core/src/features/gamification/index.ts`
- Create: `frontend/core/src/features/aggregator/store.ts`
- Create: `frontend/core/src/features/aggregator/api.ts`
- Create: `frontend/core/src/features/aggregator/index.ts`
- Modify: `frontend/core/src/index.ts`

**Interfaces:**
- Consumes: nothing from Task 1 beyond package/tooling setup.
- Produces: `useAuthStore`, `useCatalogStore`, `useOrdersStore`, `useGamificationStore`, `useAggregatorStore` (each a Zustand hook, `getState()` returns `{}`); `createAuthApiClient`, `createCatalogApiClient`, `createOrdersApiClient`, `createGamificationApiClient`, `createAggregatorApiClient` (each `(baseUrl: string) => { baseUrl: string }`) — all exported from `@teafair/core`.

- [ ] **Step 1: Write the failing test**

`frontend/core/src/features/features.test.ts`:
```ts
import { useAuthStore, createAuthApiClient } from './auth';
import { useCatalogStore, createCatalogApiClient } from './catalog';
import { useOrdersStore, createOrdersApiClient } from './orders';
import { useGamificationStore, createGamificationApiClient } from './gamification';
import { useAggregatorStore, createAggregatorApiClient } from './aggregator';

const features = [
  { name: 'auth', useStore: useAuthStore, createApiClient: createAuthApiClient },
  { name: 'catalog', useStore: useCatalogStore, createApiClient: createCatalogApiClient },
  { name: 'orders', useStore: useOrdersStore, createApiClient: createOrdersApiClient },
  { name: 'gamification', useStore: useGamificationStore, createApiClient: createGamificationApiClient },
  { name: 'aggregator', useStore: useAggregatorStore, createApiClient: createAggregatorApiClient },
];

describe.each(features)('$name feature module', ({ useStore, createApiClient }) => {
  it('exposes an empty Zustand store', () => {
    expect(useStore.getState()).toEqual({});
  });

  it('creates an API client carrying the base URL', () => {
    const client = createApiClient('https://api.teafair.dev');
    expect(client.baseUrl).toBe('https://api.teafair.dev');
  });
});
```

- [ ] **Step 2: Run the test and verify it fails**

Run (from `frontend/core`): `npx jest`
Expected: FAIL — `Cannot find module './auth' from 'src/features/features.test.ts'`

- [ ] **Step 3: Implement the auth feature module**

`frontend/core/src/features/auth/store.ts`:
```ts
import { create } from 'zustand';

interface AuthState {}

export const useAuthStore = create<AuthState>(() => ({}));
```

`frontend/core/src/features/auth/api.ts`:
```ts
export interface AuthApiClient {
  baseUrl: string;
}

export function createAuthApiClient(baseUrl: string): AuthApiClient {
  return { baseUrl };
}
```

`frontend/core/src/features/auth/index.ts`:
```ts
export * from './store';
export * from './api';
```

- [ ] **Step 4: Implement the catalog feature module**

`frontend/core/src/features/catalog/store.ts`:
```ts
import { create } from 'zustand';

interface CatalogState {}

export const useCatalogStore = create<CatalogState>(() => ({}));
```

`frontend/core/src/features/catalog/api.ts`:
```ts
export interface CatalogApiClient {
  baseUrl: string;
}

export function createCatalogApiClient(baseUrl: string): CatalogApiClient {
  return { baseUrl };
}
```

`frontend/core/src/features/catalog/index.ts`:
```ts
export * from './store';
export * from './api';
```

- [ ] **Step 5: Implement the orders feature module**

`frontend/core/src/features/orders/store.ts`:
```ts
import { create } from 'zustand';

interface OrdersState {}

export const useOrdersStore = create<OrdersState>(() => ({}));
```

`frontend/core/src/features/orders/api.ts`:
```ts
export interface OrdersApiClient {
  baseUrl: string;
}

export function createOrdersApiClient(baseUrl: string): OrdersApiClient {
  return { baseUrl };
}
```

`frontend/core/src/features/orders/index.ts`:
```ts
export * from './store';
export * from './api';
```

- [ ] **Step 6: Implement the gamification feature module**

`frontend/core/src/features/gamification/store.ts`:
```ts
import { create } from 'zustand';

interface GamificationState {}

export const useGamificationStore = create<GamificationState>(() => ({}));
```

`frontend/core/src/features/gamification/api.ts`:
```ts
export interface GamificationApiClient {
  baseUrl: string;
}

export function createGamificationApiClient(baseUrl: string): GamificationApiClient {
  return { baseUrl };
}
```

`frontend/core/src/features/gamification/index.ts`:
```ts
export * from './store';
export * from './api';
```

- [ ] **Step 7: Implement the aggregator feature module**

`frontend/core/src/features/aggregator/store.ts`:
```ts
import { create } from 'zustand';

interface AggregatorState {}

export const useAggregatorStore = create<AggregatorState>(() => ({}));
```

`frontend/core/src/features/aggregator/api.ts`:
```ts
export interface AggregatorApiClient {
  baseUrl: string;
}

export function createAggregatorApiClient(baseUrl: string): AggregatorApiClient {
  return { baseUrl };
}
```

`frontend/core/src/features/aggregator/index.ts`:
```ts
export * from './store';
export * from './api';
```

- [ ] **Step 8: Run the test and verify it passes**

Run (from `frontend/core`): `npx jest`
Expected: PASS — 11 tests passed (1 from Task 1 + 10 from this task).

- [ ] **Step 9: Update the core barrel export**

`frontend/core/src/index.ts`:
```ts
export * from './storage/types';
export * from './features/auth';
export * from './features/catalog';
export * from './features/orders';
export * from './features/gamification';
export * from './features/aggregator';
```

- [ ] **Step 10: Typecheck**

Run (from `frontend/core`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 11: Commit**

```bash
git add frontend/core
git commit -m "Add core feature module shells for auth, catalog, orders, gamification, aggregator"
```

---

## Task 3: Mobile Expo app scaffold

**Files:**
- Create: `frontend/mobile/` (via `create-expo-app`, template-generated files)
- Modify: `frontend/mobile/app.json`
- Modify: `frontend/mobile/package.json`
- Modify: `frontend/package.json`

**Interfaces:**
- Consumes: nothing yet (core is wired in Task 4).
- Produces: a running Expo dev-client app at `frontend/mobile`, `applicationId` `com.teafair.app`.

- [ ] **Step 1: Scaffold the Expo app**

Run (from `frontend/`): `npx create-expo-app@latest mobile --template blank-typescript`
Expected: creates `frontend/mobile/` with `App.tsx`, `app.json`, `package.json`, `tsconfig.json`, `assets/`.

- [ ] **Step 2: Install expo-dev-client**

Run (from `frontend/mobile`): `npx expo install expo-dev-client`
Expected: adds `expo-dev-client` to `frontend/mobile/package.json` dependencies, installs it.

- [ ] **Step 3: Set the Android app identity**

Open `frontend/mobile/app.json`. Ensure the `expo` object contains an `android` object with a `package` key set to `"com.teafair.app"`. If `android` doesn't exist, add it:

```json
{
  "expo": {
    "android": {
      "package": "com.teafair.app"
    }
  }
}
```
(Merge this into the existing generated `app.json` — do not remove other existing keys like `name`, `slug`, `icon`, `splash`, `ios`, `web`.)

- [ ] **Step 4: Add mobile to the workspace root**

Modify `frontend/package.json`:
```json
{
  "name": "teafair-frontend",
  "private": true,
  "workspaces": [
    "core",
    "mobile"
  ]
}
```

- [ ] **Step 5: Install workspace dependencies**

Run (from `frontend/`): `npm install`
Expected: no errors; `frontend/mobile` is now linked as an npm workspace.

- [ ] **Step 6: Build and run on the connected Android device**

Run (from `frontend/mobile`): `npx expo run:android`
Expected: Gradle build succeeds, app installs on the connected device (`adb devices` must show a device), app launches showing the default Expo template screen with no red-box error.

- [ ] **Step 7: Commit**

```bash
git add frontend/package.json frontend/mobile
git commit -m "Scaffold Expo mobile app with dev-client and Android app id"
```

---

## Task 4: Mobile navigation and placeholder screens wired to core

**Files:**
- Create: `frontend/mobile/src/navigation/RootStackParams.ts`
- Create: `frontend/mobile/src/navigation/AppNavigator.tsx`
- Create: `frontend/mobile/src/features/auth/screens/AuthScreen.tsx`
- Create: `frontend/mobile/src/features/catalog/screens/CatalogScreen.tsx`
- Create: `frontend/mobile/src/features/orders/screens/OrdersScreen.tsx`
- Create: `frontend/mobile/src/features/gamification/screens/GamificationScreen.tsx`
- Create: `frontend/mobile/src/features/aggregator/screens/AggregatorScreen.tsx`
- Modify: `frontend/mobile/App.tsx`
- Modify: `frontend/mobile/package.json`

**Interfaces:**
- Consumes: `useAuthStore`, `useCatalogStore`, `useOrdersStore`, `useGamificationStore`, `useAggregatorStore` from `@teafair/core` (Task 2).
- Produces: `AppNavigator` component (default export from `frontend/mobile/src/navigation/AppNavigator.tsx`), `RootTabParamList` type.

- [ ] **Step 1: Add @teafair/core and React Navigation dependencies**

Modify `frontend/mobile/package.json` — add to `dependencies`:
```json
{
  "@teafair/core": "*"
}
```

Run (from `frontend/mobile`): `npx expo install @react-navigation/native @react-navigation/native-stack @react-navigation/bottom-tabs react-native-screens react-native-safe-area-context`
Expected: adds these packages at Expo-compatible versions.

Run (from `frontend/`): `npm install`
Expected: `@teafair/core` is symlinked into `frontend/mobile/node_modules/@teafair/core` via the workspace.

- [ ] **Step 2: Create the typed route params**

`frontend/mobile/src/navigation/RootStackParams.ts`:
```ts
export type RootTabParamList = {
  Auth: undefined;
  Catalog: undefined;
  Orders: undefined;
  Gamification: undefined;
  Aggregator: undefined;
};
```

- [ ] **Step 3: Create the placeholder screens**

`frontend/mobile/src/features/auth/screens/AuthScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useAuthStore } from '@teafair/core';

export function AuthScreen() {
  const state = useAuthStore();

  return (
    <View>
      <Text>Auth</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/mobile/src/features/catalog/screens/CatalogScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useCatalogStore } from '@teafair/core';

export function CatalogScreen() {
  const state = useCatalogStore();

  return (
    <View>
      <Text>Catalog</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/mobile/src/features/orders/screens/OrdersScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useOrdersStore } from '@teafair/core';

export function OrdersScreen() {
  const state = useOrdersStore();

  return (
    <View>
      <Text>Orders</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/mobile/src/features/gamification/screens/GamificationScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useGamificationStore } from '@teafair/core';

export function GamificationScreen() {
  const state = useGamificationStore();

  return (
    <View>
      <Text>Gamification</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/mobile/src/features/aggregator/screens/AggregatorScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useAggregatorStore } from '@teafair/core';

export function AggregatorScreen() {
  const state = useAggregatorStore();

  return (
    <View>
      <Text>Aggregator</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

- [ ] **Step 4: Create the app navigator**

`frontend/mobile/src/navigation/AppNavigator.tsx`:
```tsx
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { RootTabParamList } from './RootStackParams';
import { AuthScreen } from '../features/auth/screens/AuthScreen';
import { CatalogScreen } from '../features/catalog/screens/CatalogScreen';
import { OrdersScreen } from '../features/orders/screens/OrdersScreen';
import { GamificationScreen } from '../features/gamification/screens/GamificationScreen';
import { AggregatorScreen } from '../features/aggregator/screens/AggregatorScreen';

const Tab = createBottomTabNavigator<RootTabParamList>();

export function AppNavigator() {
  return (
    <NavigationContainer>
      <Tab.Navigator>
        <Tab.Screen name="Auth" component={AuthScreen} />
        <Tab.Screen name="Catalog" component={CatalogScreen} />
        <Tab.Screen name="Orders" component={OrdersScreen} />
        <Tab.Screen name="Gamification" component={GamificationScreen} />
        <Tab.Screen name="Aggregator" component={AggregatorScreen} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
```

- [ ] **Step 5: Wire the navigator into the app entry point**

Replace the contents of `frontend/mobile/App.tsx` with:
```tsx
import { AppNavigator } from './src/navigation/AppNavigator';

export default function App() {
  return <AppNavigator />;
}
```

- [ ] **Step 6: Typecheck**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add frontend/mobile
git commit -m "Wire React Navigation bottom tabs to core-backed placeholder screens"
```

---

## Task 5: NativeWind styling and Button/InputField components

**Files:**
- Create: `frontend/mobile/tailwind.config.js`
- Create: `frontend/mobile/global.css`
- Create: `frontend/mobile/nativewind-env.d.ts`
- Modify: `frontend/mobile/babel.config.js`
- Modify: `frontend/mobile/metro.config.js` (create if it doesn't exist)
- Create: `frontend/mobile/src/components/Button.tsx`
- Create: `frontend/mobile/src/components/InputField.tsx`
- Create: `frontend/mobile/src/components/index.ts`
- Modify: `frontend/mobile/App.tsx`
- Modify: `frontend/mobile/src/features/auth/screens/AuthScreen.tsx`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Button` (`{ label: string; onPress: () => void; disabled?: boolean }`), `InputField` (`{ label: string } & TextInputProps`), both exported from `frontend/mobile/src/components/index.ts`.

- [ ] **Step 1: Install NativeWind and Tailwind**

Run (from `frontend/mobile`): `npx expo install nativewind tailwindcss@^3.4.3`
Expected: adds `nativewind` and `tailwindcss` to `frontend/mobile/package.json`.

- [ ] **Step 2: Configure Tailwind**

`frontend/mobile/tailwind.config.js`:
```js
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./App.tsx', './src/**/*.{js,jsx,ts,tsx}'],
  presets: [require('nativewind/preset')],
  theme: {
    extend: {},
  },
  plugins: [],
};
```

`frontend/mobile/global.css`:
```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

`frontend/mobile/nativewind-env.d.ts`:
```ts
/// <reference types="nativewind/types" />
```

- [ ] **Step 3: Configure Babel and Metro**

Replace `frontend/mobile/babel.config.js` with:
```js
module.exports = function (api) {
  api.cache(true);
  return {
    presets: [
      ['babel-preset-expo', { jsxImportSource: 'nativewind' }],
      'nativewind/babel',
    ],
  };
};
```

Create (or replace) `frontend/mobile/metro.config.js`:
```js
const { getDefaultConfig } = require('expo/metro-config');
const { withNativeWind } = require('nativewind/metro');

const config = getDefaultConfig(__dirname);

module.exports = withNativeWind(config, { input: './global.css' });
```

- [ ] **Step 4: Import the global stylesheet in the app entry point**

Modify `frontend/mobile/App.tsx` to add the import at the top:
```tsx
import './global.css';
import { AppNavigator } from './src/navigation/AppNavigator';

export default function App() {
  return <AppNavigator />;
}
```

- [ ] **Step 5: Create Button**

`frontend/mobile/src/components/Button.tsx`:
```tsx
import { Pressable, Text } from 'react-native';

interface ButtonProps {
  label: string;
  onPress: () => void;
  disabled?: boolean;
}

export function Button({ label, onPress, disabled }: ButtonProps) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      className={`items-center justify-center rounded-md px-4 py-3 ${
        disabled ? 'bg-gray-300' : 'bg-blue-600'
      }`}
    >
      <Text className="text-base font-semibold text-white">{label}</Text>
    </Pressable>
  );
}
```

- [ ] **Step 6: Create InputField**

`frontend/mobile/src/components/InputField.tsx`:
```tsx
import { Text, TextInput, View } from 'react-native';
import type { TextInputProps } from 'react-native';

interface InputFieldProps extends TextInputProps {
  label: string;
}

export function InputField({ label, ...textInputProps }: InputFieldProps) {
  return (
    <View className="mb-4">
      <Text className="mb-1 text-sm font-medium text-gray-700">{label}</Text>
      <TextInput
        className="rounded-md border border-gray-300 px-3 py-2 text-base"
        {...textInputProps}
      />
    </View>
  );
}
```

- [ ] **Step 7: Create the components barrel export**

`frontend/mobile/src/components/index.ts`:
```ts
export * from './Button';
export * from './InputField';
```

- [ ] **Step 8: Use Button and InputField in AuthScreen so they're exercised by the final build validation**

Replace `frontend/mobile/src/features/auth/screens/AuthScreen.tsx` with:
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
      <Button label="Continue" onPress={() => {}} />
    </View>
  );
}
```

- [ ] **Step 9: Typecheck**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 10: Commit**

```bash
git add frontend/mobile
git commit -m "Add NativeWind styling and Button/InputField components"
```

---

## Task 6: expo-secure-store adapter for core's Storage interface

**Files:**
- Create: `frontend/mobile/src/storage/secureStore.ts`

**Interfaces:**
- Consumes: `Storage` interface from `@teafair/core` (Task 1).
- Produces: `secureStorage: Storage`, exported from `frontend/mobile/src/storage/secureStore.ts`.

- [ ] **Step 1: Install expo-secure-store**

Run (from `frontend/mobile`): `npx expo install expo-secure-store`
Expected: adds `expo-secure-store` to `frontend/mobile/package.json`.

- [ ] **Step 2: Implement the adapter**

`frontend/mobile/src/storage/secureStore.ts`:
```ts
import * as SecureStore from 'expo-secure-store';
import type { Storage } from '@teafair/core';

export const secureStorage: Storage = {
  async getItem(key: string): Promise<string | null> {
    return SecureStore.getItemAsync(key);
  },
  async setItem(key: string, value: string): Promise<void> {
    await SecureStore.setItemAsync(key, value);
  },
  async removeItem(key: string): Promise<void> {
    await SecureStore.deleteItemAsync(key);
  },
};
```

- [ ] **Step 3: Typecheck (this is the acceptance gate — if `secureStorage` doesn't satisfy every method of `Storage`, this fails)**

Run (from `frontend/mobile`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add frontend/mobile/src/storage
git commit -m "Add expo-secure-store adapter implementing core Storage interface"
```

---

## Task 7: Final mobile build validation

**Files:**
- None (validation-only task).

**Interfaces:**
- Consumes: everything from Tasks 3-6.
- Produces: nothing new — confirms the mobile app matches the spec's Goal.

- [ ] **Step 1: Confirm a device is connected**

Run: `adb devices`
Expected: at least one line with status `device` (not `unauthorized` or empty).

- [ ] **Step 2: Build and run**

Run (from `frontend/mobile`): `npx expo run:android`
Expected: Gradle build succeeds, app installs and launches on the device with no red-box error.

- [ ] **Step 3: Manually verify each tab**

In the running app, tap each of the 5 bottom tabs (Auth, Catalog, Orders, Gamification, Aggregator).
Expected: each screen renders its feature name and `{}` (the empty store state) with no crash. The Auth tab additionally shows a styled email input field and a blue "Continue" button.

- [ ] **Step 4: Commit (only if any fixes were needed to reach a passing state; otherwise skip)**

```bash
git add frontend/mobile
git commit -m "Fix mobile app issues found during final build validation"
```

---

## Task 8: Windows app scaffold (no build)

**Files:**
- Create: `frontend/windows/` (via `react-native init` + `react-native-windows-init`, tool-generated files)
- Modify: `frontend/package.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a scaffolded bare RN + react-native-windows project at `frontend/windows`, not build-validated (per Global Constraints).

- [ ] **Step 1: Scaffold the bare RN project**

Run (from `frontend/`): `npx react-native@latest init TeafairWindows --directory windows --npm`
Expected: creates `frontend/windows/` with a TypeScript bare RN project (`App.tsx`, `package.json`, `index.js`, `android/`, `ios/`).

- [ ] **Step 2: Add the react-native-windows platform**

Run (from `frontend/windows`): `npx react-native-windows-init --overwrite`
Expected: adds a `windows/` subfolder inside `frontend/windows` containing the Visual Studio solution (`.sln`), `index.windows.js`, and updates `package.json` with a `react-native-windows` dependency.

- [ ] **Step 3: Add windows to the workspace root**

Modify `frontend/package.json`:
```json
{
  "name": "teafair-frontend",
  "private": true,
  "workspaces": [
    "core",
    "mobile",
    "windows"
  ]
}
```

- [ ] **Step 4: Add @teafair/core as a dependency**

Modify `frontend/windows/package.json` — add to `dependencies`:
```json
{
  "@teafair/core": "*"
}
```

- [ ] **Step 5: Install workspace dependencies**

Run (from `frontend/`): `npm install`
Expected: no errors; `@teafair/core` is symlinked into `frontend/windows/node_modules/@teafair/core`.

- [ ] **Step 6: Verify scaffold files exist (no build attempted)**

Confirm these paths exist: `frontend/windows/package.json`, `frontend/windows/windows/` (folder containing the `.sln`), `frontend/windows/App.tsx`.

- [ ] **Step 7: Commit**

```bash
git add frontend/package.json frontend/windows
git commit -m "Scaffold react-native-windows app (not build-validated)"
```

---

## Task 9: Windows navigation, placeholder screens, and async-storage adapter

**Files:**
- Create: `frontend/windows/src/navigation/RootStackParams.ts`
- Create: `frontend/windows/src/navigation/AppNavigator.tsx`
- Create: `frontend/windows/src/features/auth/screens/AuthScreen.tsx`
- Create: `frontend/windows/src/features/catalog/screens/CatalogScreen.tsx`
- Create: `frontend/windows/src/features/orders/screens/OrdersScreen.tsx`
- Create: `frontend/windows/src/features/gamification/screens/GamificationScreen.tsx`
- Create: `frontend/windows/src/features/aggregator/screens/AggregatorScreen.tsx`
- Create: `frontend/windows/src/storage/asyncStorage.ts`
- Modify: `frontend/windows/App.tsx`
- Modify: `frontend/windows/package.json`

**Interfaces:**
- Consumes: `useAuthStore`, `useCatalogStore`, `useOrdersStore`, `useGamificationStore`, `useAggregatorStore`, `Storage` from `@teafair/core` (Tasks 1-2).
- Produces: `AppNavigator` component and `asyncStorage: Storage`, mirroring the mobile app's interfaces.

- [ ] **Step 1: Install React Navigation and async-storage**

Run (from `frontend/windows`): `npm install @react-navigation/native @react-navigation/native-stack @react-navigation/bottom-tabs react-native-screens react-native-safe-area-context @react-native-async-storage/async-storage`
Expected: adds these to `frontend/windows/package.json`.

- [ ] **Step 2: Create the typed route params**

`frontend/windows/src/navigation/RootStackParams.ts`:
```ts
export type RootTabParamList = {
  Auth: undefined;
  Catalog: undefined;
  Orders: undefined;
  Gamification: undefined;
  Aggregator: undefined;
};
```

- [ ] **Step 3: Create the placeholder screens**

`frontend/windows/src/features/auth/screens/AuthScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useAuthStore } from '@teafair/core';

export function AuthScreen() {
  const state = useAuthStore();

  return (
    <View>
      <Text>Auth</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/windows/src/features/catalog/screens/CatalogScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useCatalogStore } from '@teafair/core';

export function CatalogScreen() {
  const state = useCatalogStore();

  return (
    <View>
      <Text>Catalog</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/windows/src/features/orders/screens/OrdersScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useOrdersStore } from '@teafair/core';

export function OrdersScreen() {
  const state = useOrdersStore();

  return (
    <View>
      <Text>Orders</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/windows/src/features/gamification/screens/GamificationScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useGamificationStore } from '@teafair/core';

export function GamificationScreen() {
  const state = useGamificationStore();

  return (
    <View>
      <Text>Gamification</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

`frontend/windows/src/features/aggregator/screens/AggregatorScreen.tsx`:
```tsx
import { Text, View } from 'react-native';
import { useAggregatorStore } from '@teafair/core';

export function AggregatorScreen() {
  const state = useAggregatorStore();

  return (
    <View>
      <Text>Aggregator</Text>
      <Text>{JSON.stringify(state)}</Text>
    </View>
  );
}
```

- [ ] **Step 4: Create the app navigator**

`frontend/windows/src/navigation/AppNavigator.tsx`:
```tsx
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { RootTabParamList } from './RootStackParams';
import { AuthScreen } from '../features/auth/screens/AuthScreen';
import { CatalogScreen } from '../features/catalog/screens/CatalogScreen';
import { OrdersScreen } from '../features/orders/screens/OrdersScreen';
import { GamificationScreen } from '../features/gamification/screens/GamificationScreen';
import { AggregatorScreen } from '../features/aggregator/screens/AggregatorScreen';

const Tab = createBottomTabNavigator<RootTabParamList>();

export function AppNavigator() {
  return (
    <NavigationContainer>
      <Tab.Navigator>
        <Tab.Screen name="Auth" component={AuthScreen} />
        <Tab.Screen name="Catalog" component={CatalogScreen} />
        <Tab.Screen name="Orders" component={OrdersScreen} />
        <Tab.Screen name="Gamification" component={GamificationScreen} />
        <Tab.Screen name="Aggregator" component={AggregatorScreen} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
```

- [ ] **Step 5: Wire the navigator into the app entry point**

Replace the contents of `frontend/windows/App.tsx` with:
```tsx
import { AppNavigator } from './src/navigation/AppNavigator';

export default function App() {
  return <AppNavigator />;
}
```

- [ ] **Step 6: Implement the async-storage adapter**

`frontend/windows/src/storage/asyncStorage.ts`:
```ts
import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Storage } from '@teafair/core';

export const asyncStorage: Storage = {
  async getItem(key: string): Promise<string | null> {
    return AsyncStorage.getItem(key);
  },
  async setItem(key: string, value: string): Promise<void> {
    await AsyncStorage.setItem(key, value);
  },
  async removeItem(key: string): Promise<void> {
    await AsyncStorage.removeItem(key);
  },
};
```

- [ ] **Step 7: Add @teafair/core to dependencies (if not already present from Task 8)**

Confirm `frontend/windows/package.json` `dependencies` includes `"@teafair/core": "*"`. If missing, add it and run `npm install` from `frontend/`.

- [ ] **Step 8: Typecheck**

Run (from `frontend/windows`): `npx tsc --noEmit`
Expected: no output, exit code 0.

- [ ] **Step 9: Commit**

```bash
git add frontend/windows
git commit -m "Add Windows navigation, placeholder screens, and async-storage adapter"
```
