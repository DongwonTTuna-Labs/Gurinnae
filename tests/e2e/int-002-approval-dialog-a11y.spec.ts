import { expect, test } from "@playwright/test";

const reviewConsole = "http://127.0.0.1:29102";
const mockApi = "http://127.0.0.1:29100";
const proposalId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

test("INT-002 decision dialog traps and restores keyboard focus", async ({
  page,
  request,
}) => {
  await request.post(`${mockApi}/_test/reset`);
  await page.goto(
    `${reviewConsole}/auth/login?returnTo=${encodeURIComponent("/internal/my-work")}`,
    { waitUntil: "networkidle" },
  );
  await expect(page).toHaveURL(`${reviewConsole}/internal/my-work`);

  const card = page.locator(`[data-proposal-id="${proposalId}"]`);
  await expect(card).toBeVisible();
  await card.getByRole("link", { name: "이 제안 상세 확인" }).click();
  await expect(page).toHaveURL(new RegExp(`proposalId=${proposalId}`));

  const opener = page.locator('[data-decision="approve"]');
  await opener.focus();
  await opener.press("Enter");
  const dialog = page.locator("#approval-decision-int-002");
  await expect(dialog).toBeVisible();
  await expect(page.locator("#approval-decision-int-002-title")).toBeFocused();

  const focusable = dialog.locator(
    "button:not([disabled]), input:not([disabled]):not([type='hidden']), select:not([disabled]), textarea:not([disabled]), a[href]",
  );
  expect(await focusable.count()).toBeGreaterThan(1);
  const firstId = await focusable.first().getAttribute("id");
  expect(firstId).toBeTruthy();
  await focusable.last().focus();
  await page.keyboard.press("Tab");
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.id ?? ""))
    .toBe(firstId);

  await page.keyboard.press("Escape");
  await expect(dialog).not.toBeVisible();
  await expect(opener).toBeFocused();
});
