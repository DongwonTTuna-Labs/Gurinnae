import { expect, test } from "@playwright/test";

const review = "http://127.0.0.1:29102";
const responsePortal = "http://127.0.0.1:29103";

test("AUTH-001 initial sign-in uses one neutral status before its action", async ({
  context,
  page,
}) => {
  await context.clearCookies();

  const ssr = await page.request.get(`${review}/auth/sign-in`);
  expect(ssr.status()).toBe(200);
  const html = await ssr.text();
  expect(html).not.toContain('class="state badge status-alert');
  expect(html).not.toContain('class="inline-state');
  expect(html).not.toContain('role="alert"');

  await page.goto(`${review}/auth/sign-in`, { waitUntil: "networkidle" });
  const guidance = page.getByTestId("auth-001__state_live");
  await expect(guidance).toHaveText(
    "내부 화면을 사용하려면 로그인해야 합니다.",
  );
  await expect(guidance).toHaveClass(/notice/);
  await expect(page.locator('[role="alert"]')).toHaveCount(0);
  await expect(page.locator(".inline-state.conflict")).toHaveCount(0);
  await expect(page.locator('form[data-action-id="sign-in"]')).toBeVisible();
  await expect(
    page.getByTestId("auth_001__section__environment"),
  ).toBeVisible();
  await expect(page.getByTestId("auth_001__section__signin")).toBeVisible();
  await expect(page.getByTestId("auth_001__section__support")).toBeVisible();
});

test("RSP-001 without a scoped session renders guidance without protected chrome", async ({
  context,
  page,
}) => {
  await context.clearCookies();

  const ssr = await page.request.get(`${responsePortal}/respond/access`);
  expect(ssr.status()).toBe(200);
  const html = await ssr.text();
  expect(html).not.toContain('class="form-card');
  expect(html).not.toContain('id="page-actions"');
  expect(html).not.toContain("<form");
  expect(html).not.toContain('role="alert"');

  await page.goto(`${responsePortal}/respond/access`, {
    waitUntil: "networkidle",
  });
  const guidance = page.getByTestId("rsp-001__state_live");
  await expect(guidance).toHaveText(
    "보안 링크의 발신자를 확인하고 링크와 인증 정보를 공유하지 마세요.",
  );
  await expect(guidance).toHaveClass(/notice/);
  await expect(page.getByTestId("rsp-001__heading")).toBeVisible();
  await expect(page.locator('[role="alert"]')).toHaveCount(0);
  await expect(page.locator(".form-card")).toHaveCount(0);
  await expect(page.locator("#page-actions")).toHaveCount(0);
  await expect(page.locator("form")).toHaveCount(0);
  const sectionIds = await page
    .locator("main section[data-component]")
    .evaluateAll((sections) => sections.map((section) => section.id));
  expect(sectionIds).toEqual([
    "identity",
    "security",
    "deadline",
    "process",
    "verification",
  ]);
});
