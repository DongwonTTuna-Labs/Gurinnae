import { expect, test } from "@playwright/test";

const review = "http://127.0.0.1:29102";
const mock = "http://127.0.0.1:29100";

test("anonymous sign-in action uses the existing login bootstrap without widening origin trust", async ({
  context,
  page,
  request,
}) => {
  await request.post(`${mock}/_test/reset`);
  await context.clearCookies();

  const crossOrigin = await page.request.post(
    `${review}/auth/sign-in?/sign-in`,
    {
      headers: {
        origin: "https://attacker.invalid",
        "content-type": "application/x-www-form-urlencoded",
      },
      maxRedirects: 0,
    },
  );
  expect(crossOrigin.status()).toBe(403);
  expect(crossOrigin.headers().location).toBeUndefined();
  expect(await context.cookies()).toHaveLength(0);

  const returnTo = "/internal/dashboard?from=anonymous-sign-in";
  await page.goto(
    `${review}/auth/sign-in?returnTo=${encodeURIComponent(returnTo)}`,
  );
  const signIn = page.locator('form[data-action-id="sign-in"]');
  await expect(signIn).toBeVisible();

  const actionResponse = page.waitForResponse(
    (response) =>
      response.request().method() === "POST" &&
      response.url().includes("/auth/sign-in?/sign-in"),
  );
  await signIn.locator('button[type="submit"]').click();
  expect((await actionResponse).status()).toBe(303);

  await expect(page).toHaveURL(`${review}${returnTo}`);
  await expect(page.getByText("E2E 검토자")).toBeVisible();
});
