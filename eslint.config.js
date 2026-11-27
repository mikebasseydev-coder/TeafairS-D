// The app's lint (Spec B §3): expo's rules plus the feature import graph,
//   shared ← auth ← tenant ← shell ← { domain features }
// `shared` imports no feature; a domain feature imports only the barrels of
// auth, tenant and shell, never another domain feature; routes import barrels.
const { defineConfig } = require("eslint/config");
const expoConfig = require("eslint-config-expo/flat");

const DOMAIN = ["catalogue", "stock", "field", "fulfilment", "support", "chat", "notifications", "monvelo", "gallery"];
const barrel = (f) => `./${f}/index.ts`;

const zones = [
  { target: "./src/shared", from: "./src/features", message: "shared imports no feature (Spec B §3)" },
  { target: "./src/features/auth", from: "./src/features", except: ["./auth"], message: "auth imports only shared" },
  { target: "./src/features/tenant", from: "./src/features", except: ["./tenant", barrel("auth")], message: "tenant imports only the auth barrel" },
  {
    target: "./src/features/shell",
    from: "./src/features",
    except: ["./shell", barrel("auth"), barrel("tenant")],
    message: "shell imports only the auth and tenant barrels",
  },
  ...DOMAIN.map((d) => ({
    target: `./src/features/${d}`,
    from: "./src/features",
    except: [`./${d}`, barrel("auth"), barrel("tenant"), barrel("shell")],
    message: `${d} may import only the auth, tenant and shell barrels, never another domain feature (Spec B §3, A6 §15)`,
  })),
];

module.exports = defineConfig([
  expoConfig,
  // explicit, because eslint-plugin-react's version detection calls an API ESLint 10 removed
  { settings: { react: { version: "19.3" } } },
  { ignores: ["dist-web/*", "supabase/*", "node_modules/*", "playwright-report/*", "test-results/*", ".design-refs/*"] },
  {
    files: ["src/**/*.{ts,tsx}"],
    settings: {
      "import/resolver": { typescript: { project: "./tsconfig.json" }, node: true },
    },
    rules: {
      "import/no-cycle": "error",
      "import/no-restricted-paths": ["error", { zones }],
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            { group: ["@/features/*/*", "@/features/*/**"], message: "import a feature through its barrel (@/features/<name>)" },
          ],
        },
      ],
      "no-console": "error",
    },
  },
]);
