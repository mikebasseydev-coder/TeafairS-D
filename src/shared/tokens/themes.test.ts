import { primitives } from "./primitives";
import { PLATFORM_ROLES, TENANT_ROLES, defaultThemeForRole, effectiveTheme } from "./role-theme";
import { SEMANTIC_TOKENS, THEMES, TONES } from "./semantic";
import { resolveTheme, themeVariables } from "./themes";

describe("role defaults (ruling 2026-11-27)", () => {
  it.each(["ZSA", "ASA", "TM", "RETAIL_SHOP_OWNER", "POS_AGENT"] as const)("%s starts in daylight", (role) => {
    expect(defaultThemeForRole(role)).toBe("daylight");
  });
  it.each(["ZSM", "ASM", "DSM", "DSA", "LOGISTICS_MANAGER", "CLIENT_SERVICE_MANAGER", "TENANT_ADMIN"] as const)(
    "%s starts in standard",
    (role) => {
      expect(defaultThemeForRole(role)).toBe("standard");
    },
  );
  it("a person with no membership (a Monvelo agent member) starts in standard", () => {
    expect(defaultThemeForRole(null)).toBe("standard");
  });
  it("dark is never a role default", () => {
    expect(TENANT_ROLES.map(defaultThemeForRole)).not.toContain("dark");
  });
  it("the user's choice wins; clearing it returns to the role default", () => {
    expect(effectiveTheme("dark", "ZSA")).toBe("dark");
    expect(effectiveTheme("standard", "ZSA")).toBe("standard");
    expect(effectiveTheme(null, "ZSA")).toBe("daylight");
  });
  it("names exactly the two enums of Spec B §1", () => {
    expect(TENANT_ROLES).toHaveLength(12);
    expect([...PLATFORM_ROLES]).toEqual(["PLATFORM_SUPER_ADMIN", "MONVELO_OPERATOR", "MONVELO_FINANCE"]);
  });
});

describe("theme resolution", () => {
  const allowed = new Set<string>(Object.values(primitives));
  it.each(THEMES)("%s resolves every semantic token and tone to a primitive", (name) => {
    const r = resolveTheme(name);
    for (const t of SEMANTIC_TOKENS) expect(allowed.has(r.colors[t])).toBe(true);
    for (const tone of TONES) {
      expect(allowed.has(r.tones[tone].mark)).toBe(true);
      expect(allowed.has(r.tones[tone].text)).toBe(true);
      expect(allowed.has(r.tones[tone].subtle)).toBe(true);
    }
  });
  it("exposes one CSS variable per token and three per tone", () => {
    const vars = themeVariables("standard");
    expect(Object.keys(vars)).toHaveLength(SEMANTIC_TOKENS.length + TONES.length * 3);
    expect(vars["--canvas"]).toBe(primitives.canvas);
    expect(vars["--tone-danger-text"]).toBe(primitives.red);
  });
  it("matches FIGMA.md §3 at the points the spec names", () => {
    expect(resolveTheme("daylight").colors["ink-muted"]).toBe(primitives.ink);
    expect(resolveTheme("daylight").colors.hairline).toBe(primitives.slate);
    expect(resolveTheme("dark").colors.control).toBe(primitives.mist);
    expect(resolveTheme("dark").tones.danger.text).toBe(primitives["red-soft"]);
    expect(resolveTheme("dark").tones.info.mark).toBe(primitives.sky);
    expect(resolveTheme("standard").colors["action-strong"]).toBe(primitives.botanical);
  });
});
