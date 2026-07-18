import { randomUUID } from "node:crypto";
import { expect, test } from "@playwright/test";
import { sha256, state } from "./submission-routing.shared";

test("magic-link exchanges use no-referrer while canonical forms retain a same-origin Origin", async ({
  request,
}) => {
  for (const contract of [
    {
      exchange: "http://127.0.0.1:29103/respond/access",
      canonical: "http://127.0.0.1:29103/respond/access",
    },
    {
      exchange: "http://127.0.0.1:29101/correction-request/receipt",
      canonical: "http://127.0.0.1:29101/correction-request/receipt",
    },
  ]) {
    const response = await request.get(
      `${contract.exchange}?token=${encodeURIComponent(`referrer-${randomUUID()}`)}`,
      { maxRedirects: 0 },
    );
    expect(response.status()).toBe(303);
    expect(response.headers()["referrer-policy"]).toBe("no-referrer");
    expect(response.headers().location).toBe(
      new URL(contract.canonical).pathname,
    );

    const canonical = await request.get(contract.canonical);
    expect(canonical.status()).toBe(200);
    expect(canonical.headers()["referrer-policy"]).toBe(
      "strict-origin-when-cross-origin",
    );
  }
});

for (const contract of [
  {
    name: "response access",
    url: "http://127.0.0.1:29103/respond/access",
    exchangePath: "/v1/submission-session/response:exchange",
    readPath: "/v1/response-session/access-status",
  },
  {
    name: "response receipt",
    url: "http://127.0.0.1:29103/respond/receipt",
    exchangePath: "/v1/submission-session/response-receipt:exchange",
    readPath: "/v1/response-receipt",
  },
  {
    name: "correction receipt",
    url: "http://127.0.0.1:29101/correction-request/receipt",
    exchangePath: "/v1/submission-session/correction-receipt:exchange",
    readPath: "/v1/correction-receipt",
  },
  {
    name: "subscription management",
    url: "http://127.0.0.1:29101/subscription/manage",
    exchangePath: "/v1/submission-session/subscription-management:exchange",
    readPath: "/v1/subscription-session",
  },
]) {
  test(`${contract.name} exchanges the token and uses the submission client`, async ({
    page,
    request,
  }) => {
    const oneTimeToken = `${contract.name}-${randomUUID()}`;
    await page.goto(
      `${contract.url}?token=${encodeURIComponent(oneTimeToken)}`,
      {
        waitUntil: "networkidle",
      },
    );
    expect(page.url()).toBe(contract.url);
    const observed = await state(request);
    expect(observed.submissionExchanges).toContainEqual(
      expect.objectContaining({
        path: contract.exchangePath,
        tokenSha256: sha256(oneTimeToken),
      }),
    );
    expect(observed.submissionReads).toContainEqual(
      expect.objectContaining({ path: contract.readPath }),
    );
  });
}

test("failed token exchange removes the bearer token from the URL", async ({
  page,
}) => {
  const oneTimeToken = `invalid-${randomUUID()}`;
  await page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(oneTimeToken)}`,
    { waitUntil: "networkidle" },
  );
  expect(page.url()).not.toContain("token=");
  expect(page.url()).not.toContain(encodeURIComponent(oneTimeToken));
  await expect(page.locator(".notice")).toContainText("ONE_TIME_TOKEN_INVALID");
});

for (const retryContract of [
  {
    name: "response portal",
    url: "http://127.0.0.1:29103/respond/access",
  },
  {
    name: "public web",
    url: "http://127.0.0.1:29101/correction-request/receipt",
  },
]) {
  test(`${retryContract.name} one-time token retries use a fresh idempotency scope`, async ({
    page,
    request,
    browser,
  }) => {
    const oneTimeToken = `${retryContract.name}-one-time-${randomUUID()}`;
    const target = `${retryContract.url}?token=${encodeURIComponent(oneTimeToken)}`;
    await page.goto(target, { waitUntil: "networkidle" });
    expect(page.url()).toBe(retryContract.url);

    const secondContext = await browser.newContext();
    try {
      const secondPage = await secondContext.newPage();
      await secondPage.goto(target, { waitUntil: "networkidle" });
      expect(secondPage.url()).not.toContain("token=");
      await expect(secondPage.locator(".notice")).toContainText(
        "ONE_TIME_TOKEN_INVALID",
      );
    } finally {
      await secondContext.close();
    }

    const attempts = (await state(request)).submissionExchanges.filter(
      (exchange) => exchange.tokenSha256 === sha256(oneTimeToken),
    );
    expect(attempts).toHaveLength(2);
    expect(attempts.map((attempt) => attempt.accepted)).toEqual([true, false]);
    expect(
      new Set(attempts.map((attempt) => attempt.idempotencyKeySha256)).size,
    ).toBe(2);
  });
}
