import { expect, test } from "@playwright/test";

const publicBase = "http://127.0.0.1:29101";
const mockBase = "http://127.0.0.1:29100";
const independenceNotice = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";

test.beforeEach(async ({ request }) => {
  await request.post(`${mockBase}/_test/reset`);
});

test("[PUB-035-001] TEST_ONLY donation surface keeps the exact independence boundary", async ({
  page,
}) => {
  await page.goto(`${publicBase}/donate`, { waitUntil: "networkidle" });

  await expect(page.locator("main#main-content")).toHaveAttribute(
    "data-screen-id",
    "PUB-035",
  );
  await expect(page.locator("#independence strong")).toHaveText(
    independenceNotice,
  );
  await expect(page.locator("#mode")).toContainText(
    "테스트 모드 · 운영 사용 불가",
  );
  const form = page.locator('form[data-action-id="queue-donation"]');
  await expect(form).toBeVisible();
  await expect(
    form.getByRole("button", { name: "테스트 후원 요청" }),
  ).toBeEnabled();
  await expect(
    form.getByText(independenceNotice, { exact: false }),
  ).toBeVisible();

  const document = await page.locator("html").innerText();
  expect(document).not.toMatch(
    /TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY|paymentAuthorizationToken|DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN/u,
  );
});

test("[PUB-035-002] queued fixture receipt never claims payment success or changes public access", async ({
  page,
}) => {
  await page.goto(`${publicBase}/donate`, { waitUntil: "networkidle" });
  const form = page.locator('form[data-action-id="queue-donation"]');

  await form
    .getByRole("radio", { name: /테스트 픽스처/u })
    .first()
    .check();
  await form.getByRole("radio", { name: "정기 후원" }).check();
  await form.getByLabel("결제 제공자 (필수)").selectOption("TOSS_PAYMENTS");
  await form
    .getByRole("checkbox", { name: new RegExp(independenceNotice, "u") })
    .check();
  await form.getByRole("button", { name: "테스트 후원 요청" }).click();

  const receipt = page.locator("#receipt");
  await expect(
    receipt.getByRole("heading", { name: "후원 요청 접수" }),
  ).toBeFocused();
  await expect(receipt).toContainText("접수 대기");
  await expect(receipt).toContainText("접수 대기는 결제 성공이 아니며");
  await expect(receipt).not.toContainText("결제 성공했습니다");
  await expect(receipt).not.toContainText("결제 완료");

  await page.goto(`${publicBase}/cases`, { waitUntil: "networkidle" });
  await expect(page.locator("main#main-content")).toHaveAttribute(
    "data-screen-id",
    "PUB-003",
  );
  await expect(page.locator(".public-ledger tbody tr")).toHaveCount(8);
});
