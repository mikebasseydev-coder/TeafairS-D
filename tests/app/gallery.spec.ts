// Slice B1 (Spec B §11): the primitives gallery at phone (390x844) and tablet
// (768x1024) widths, in all three themes.
import { expect, test, type Page } from "@playwright/test";
import { resolveTheme } from "../../src/shared/tokens/themes";
import { THEMES, type SemanticToken } from "../../src/shared/tokens/semantic";

function rgb(hex: string): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgb(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255})`;
}

async function openGallery(page: Page, query: string) {
  await page.goto(`/gallery?${query}`);
  await expect(page.getByTestId("gallery")).toBeVisible();
  await expect(page.getByTestId("bento").getByTestId("tile-shops")).toBeVisible();
  // the emblem is an image: wait until every one has decoded
  await page.waitForFunction(() => [...document.images].every((i) => i.complete && i.naturalWidth > 0));
}

const SWATCHES: SemanticToken[] = ["canvas", "surface", "ink", "ink-muted", "hairline", "control", "focus", "action", "action-strong", "skeleton"];

for (const theme of THEMES) {
  test.describe(`the ${theme} theme`, () => {
    test("renders without horizontal scroll", async ({ page }) => {
      await openGallery(page, `theme=${theme}`);
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        const scrollers = [...document.querySelectorAll<HTMLElement>("*")].filter((el) => {
          const s = getComputedStyle(el);
          return /(auto|scroll)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 1;
        });
        return { page: doc.scrollWidth - doc.clientWidth, scrollers: scrollers.length };
      });
      expect(overflow).toEqual({ page: 0, scrollers: 0 });
    });

    test("its colours are the §4.2 primitives through the semantic tokens", async ({ page }) => {
      await openGallery(page, `theme=${theme}`);
      const r = resolveTheme(theme);
      await expect(page.getByTestId("gallery-theme")).toHaveAttribute("data-theme", theme);
      for (const token of SWATCHES) {
        await expect(page.getByTestId(`swatch-${token}`), token).toHaveCSS("background-color", rgb(r.colors[token]));
      }
      for (const tone of ["danger", "info", "warning", "success"] as const) {
        const badge = page.getByTestId(`badge-${tone}`);
        await expect(badge, `${tone} border`).toHaveCSS("border-top-color", rgb(r.tones[tone].mark));
        await expect(badge, `${tone} subtle`).toHaveCSS("background-color", rgb(r.tones[tone].subtle));
        await expect(badge.locator("div[dir]").last(), `${tone} text`).toHaveCSS("color", rgb(r.tones[tone].text));
      }
      // daylight badges carry a 1.5 px border (FIGMA.md §3). Chromium snaps the computed width
      // to whole pixels at a device pixel ratio of 1, so read the declared style.
      const declared = await page.getByTestId("badge-danger").evaluate((e) => (e as HTMLElement).style.borderTopWidth || (e as HTMLElement).style.borderWidth);
      expect(declared).toBe(theme === "daylight" ? "1.5px" : "1px");
    });

    test("matches its screenshots", async ({ page }) => {
      await openGallery(page, `theme=${theme}`);
      await expect(page).toHaveScreenshot(`${theme}-top.png`);
      await expect(page.getByTestId("badges")).toHaveScreenshot(`${theme}-badges.png`);
      await expect(page.getByTestId("bento")).toHaveScreenshot(`${theme}-bento.png`);
      await expect(page.getByTestId("emblems")).toHaveScreenshot(`${theme}-emblems.png`);
    });
  });
}

test("switching theme swaps the variables, not the classes", async ({ page }) => {
  await openGallery(page, "theme=standard");
  const swatch = page.getByTestId("swatch-canvas");
  const classBefore = await swatch.getAttribute("class");
  await page.getByTestId("theme-dark").click();
  await expect(swatch).toHaveCSS("background-color", rgb(resolveTheme("dark").colors.canvas));
  expect(await swatch.getAttribute("class")).toBe(classBefore);
});

test("a Bento tile in error leaves its neighbours rendered", async ({ page }, info) => {
  await openGallery(page, "theme=standard");
  const bento = page.getByTestId("bento");
  await expect(bento).toHaveAttribute("data-columns", info.project.name === "phone" ? "2" : "4");

  const error = bento.getByTestId("tile-error");
  await expect(error).toHaveAttribute("data-status", "error");
  await expect(error.getByText("Network unavailable (0 retries)")).toBeVisible();
  // a render error is caught inside its own tile
  await expect(bento.getByTestId("tile-throws").getByText("Could not load")).toBeVisible();

  await expect(bento.getByTestId("tile-pipeline").getByText("24", { exact: true })).toBeVisible();
  await expect(bento.getByTestId("tile-shops").getByText("41", { exact: true })).toBeVisible();
  await expect(bento.getByTestId("tile-pledged").getByText("Unavailable offline")).toBeVisible();
  await expect(bento.getByTestId("tile-empty").getByText("No open nominations")).toBeVisible();
  await expect(bento.getByTestId("tile-loading").getByRole("progressbar", { name: "Loading" })).toBeVisible();

  await error.getByRole("button", { name: "Retry" }).click();
  await expect(error.getByText("Network unavailable (1 retries)")).toBeVisible();
  await expect(bento.getByTestId("tile-shops").getByText("41", { exact: true })).toBeVisible();

  // a 2x2 tile spans the phone's width; on a tablet it takes two of four columns
  const grid = (await bento.boundingBox())!;
  const pipeline = (await bento.getByTestId("tile-pipeline").boundingBox())!;
  const share = pipeline.width / grid.width;
  if (info.project.name === "phone") expect(share).toBeCloseTo(1, 2);
  else expect(share).toBeGreaterThan(0.45);
});

test("a list skeleton has 4–6 rows and the loaded list's height", async ({ page }) => {
  await openGallery(page, "theme=standard");
  const skeleton = page.getByTestId("list-skeleton");
  const rows = await skeleton.getByTestId("skeleton-row").count();
  expect(rows).toBeGreaterThanOrEqual(4);
  expect(rows).toBeLessThanOrEqual(6);
  const loaded = page.getByTestId("list-loaded");
  const [s, l] = [(await skeleton.boundingBox())!, (await loaded.boundingBox())!];
  expect(Math.abs(s.height - l.height)).toBeLessThanOrEqual(1);
  // one "Loading" for the region; the blocks are hidden from screen readers
  await expect(skeleton).toHaveAttribute("role", "progressbar");
  await expect(skeleton).toHaveAttribute("aria-label", "Loading");
  const visibleBlocks = await skeleton.getByTestId("skeleton-block").evaluateAll((els) => els.filter((e) => e.getAttribute("aria-hidden") !== "true").length);
  expect(visibleBlocks).toBe(0);
});

test("skeletons stop animating under reduced motion", async ({ page }) => {
  await openGallery(page, "theme=standard");
  const anim = await page.getByTestId("list-skeleton").getByTestId("skeleton-block").first().evaluate((e) => getComputedStyle(e).animationName);
  expect(anim).toBe("none");
});

test.describe("with motion allowed", () => {
  test.use({ reducedMotion: "no-preference" });
  test("the pulse animates", async ({ page }) => {
    await openGallery(page, "theme=standard");
    const anim = await page.getByTestId("list-skeleton").getByTestId("skeleton-block").first().evaluate((e) => getComputedStyle(e).animationName);
    expect(anim).toBe("pulse");
  });
});

test("the safe areas are respected", async ({ page }) => {
  await openGallery(page, "theme=standard&insets=notch");
  await expect(page.getByTestId("safe-area-probe")).toHaveAttribute("data-top", "47");
  const header = (await page.getByTestId("gallery-header").boundingBox())!;
  expect(header.y).toBeGreaterThanOrEqual(47 + 16 - 1);
  // the content ends above the home indicator: scroll to the end and measure
  const gap = await page.getByTestId("gallery").evaluate((el) => {
    el.scrollTop = el.scrollHeight;
    const content = el.firstElementChild as HTMLElement;
    const last = content.lastElementChild as HTMLElement;
    return el.getBoundingClientRect().bottom - last.getBoundingClientRect().bottom;
  });
  expect(gap).toBeGreaterThanOrEqual(34);
});

test("the emblem renders the transparent PNG at its fixed sizes with clear space", async ({ page }) => {
  await openGallery(page, "theme=standard");
  for (const size of [24, 32, 48, 64, 96]) {
    const box = (await page.getByTestId(`emblem-${size}`).boundingBox())!;
    expect(Math.round(box.width)).toBe(size + 2 * (size / 8));
    expect(Math.round(box.height)).toBe(size + 2 * (size / 8));
  }
  await expect(page.getByRole("img", { name: "Teafair" }).first()).toBeVisible();
});
