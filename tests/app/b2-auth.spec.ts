// Slice B2 (Spec B §11): email-first sign-in, invitations and the PIN, at
// phone (390x844) and tablet (768x1024). It runs against the local stack:
// `supabase start`, `pnpm functions:serve:app` (the hooks, with Resend pointed
// at the fake this config starts) and `pnpm export:web:local`. Each test makes
// its own person, so the projects never share one.
import { expect, test, type Page } from "@playwright/test";
import { createPerson, invite, latestCode } from "./support/stack";

// the local hooks share one edge runtime: one person at a time per project
test.describe.configure({ mode: "serial" });

async function signIn(page: Page, email: string) {
  await page.goto("/");
  await expect(page.getByTestId("sign-in-email")).toBeVisible();
  await page.getByLabel("Email").fill(email);
  const sentAfter = Date.now() - 1000;
  await page.getByTestId("sign-in-send").click();
  await expect(page.getByTestId("sign-in-code")).toBeVisible();
  await page.getByLabel("Sign-in code").fill(await latestCode(email, sentAfter));
  await page.getByTestId("sign-in-verify").click();
}

async function typePin(page: Page, pin: string) {
  const pad = page.getByTestId("pin-pad");
  for (const d of pin) await pad.getByRole("button", { name: d, exact: true }).click();
}

async function submitPin(page: Page, pin: string) {
  await typePin(page, pin);
  await page.getByTestId("pin-submit").click();
}

test("an invited person signs in with a code, accepts, and lands on the PIN gate", async ({ page }) => {
  const person = await createPerson("accept");
  await invite(person.id);
  const pinWrites: string[] = [];
  page.on("request", (r) => {
    const m = r.url().match(/\/rest\/v1\/rpc\/(set_tenant_pin|change_tenant_pin)/);
    if (m) pinWrites.push(m[1]);
  });

  await signIn(page, person.email);
  const card = page.getByTestId("invitation-TEAFAIR");
  await expect(card).toBeVisible();
  await expect(card).toContainText("Brand administrator");
  await card.getByTestId("invitation-accept").click();
  await expect(page.getByTestId("pin-set")).toBeVisible();

  // a weak PIN is refused before anything is sent
  for (const [weak, copy] of [
    ["7777", "Choose a PIN that is not one digit repeated."],
    ["1234", "Choose a PIN that is not a run of digits."],
    ["6543", "Choose a PIN that is not a run of digits."],
  ]) {
    await submitPin(page, weak);
    await expect(page.getByTestId("pin-message")).toHaveText(copy);
    await expect(page.getByTestId("pin-set")).toBeVisible();
  }
  expect(pinWrites).toEqual([]);

  await submitPin(page, "2580");
  await expect(page.getByTestId("pin-confirm")).toBeVisible();
  await submitPin(page, "2580");
  await expect(page.getByTestId("home")).toBeVisible();
  await expect(page.getByTestId("home-role")).toHaveText("Brand administrator");
  expect(pinWrites).toEqual(["set_tenant_pin"]);

  // a wrong current PIN is an answer with the attempts left, not an error
  await page.getByTestId("home-change-pin").click();
  await submitPin(page, "1357");
  await submitPin(page, "4826");
  await submitPin(page, "4826");
  await expect(page.getByTestId("pin-message")).toHaveText("Your current PIN was wrong. 4 attempts left.");
  await expect(page.getByTestId("pin-change-current")).toBeVisible();

  // the right one changes it
  await submitPin(page, "2580");
  await submitPin(page, "4826");
  await submitPin(page, "4826");
  await expect(page.getByTestId("pin-changed")).toBeVisible();
  expect(pinWrites).toEqual(["set_tenant_pin", "change_tenant_pin", "change_tenant_pin"]);
});

test("a decline leaves No access yet", async ({ page }) => {
  const person = await createPerson("decline");
  await invite(person.id);
  await signIn(page, person.email);
  await page.getByTestId("invitation-TEAFAIR").getByTestId("invitation-decline").click();
  await expect(page.getByTestId("access-no-access")).toBeVisible();
  await expect(page.getByTestId("access-no-access")).toContainText("No access yet");
});

test("an unknown email sees the access message", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("Email").fill(`nobody-${Date.now()}@rtm.local`);
  await page.getByTestId("sign-in-send").click();
  await expect(page.getByTestId("sign-in-failure")).toHaveText("This email has no Teafair access.");
  await expect(page.getByTestId("sign-in-email")).toBeVisible();
});
