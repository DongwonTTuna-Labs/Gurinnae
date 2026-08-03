import { randomUUID } from "node:crypto";
import { type BrowserContext, expect, type Page } from "@playwright/test";

export async function expectCanonicalSubscriptionExchange(
  page: Page,
  context: BrowserContext,
): Promise<void> {
  const pending = (await context.cookies()).find(
    (cookie) => cookie.name === "gurine_subscription_session",
  );
  expect(pending).toMatchObject({
    httpOnly: true,
    path: "/subscription",
    sameSite: "Lax",
  });

  const verificationToken = `subscription-verify-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29101/subscribe?token=${encodeURIComponent(verificationToken)}`,
    { waitUntil: "networkidle" },
  );
  await expect(page).toHaveURL(/\/subscription\/manage\?notice=/);
  expect(page.url()).not.toContain("token=");
  await expect(page.locator(".error-summary")).toHaveCount(0);
}
