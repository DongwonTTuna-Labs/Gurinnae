import { type APIRequestContext, expect, test } from "@playwright/test";

const review = "http://127.0.0.1:29102";
const mock = "http://127.0.0.1:29100";
const snapshotId = "00000000-0000-4000-8000-000000000020";
const caseId = "00000000-0000-4000-8000-000000000010";

type TestState = {
  stepUpStartCount: number;
  stepUpCallbackCount: number;
  authorizationCloseCount: number;
  sessionRevokeCount: number;
  sessionRevoked: boolean;
  commandAttempts: Array<{
    bodySha256: string;
    idempotencyKeySha256: string;
    actorAssertionSha256: string;
  }>;
  assertionOperations: Array<{
    operationId: string;
    actorAssertionSha256: string;
  }>;
};

test.describe
  .serial("Browser Identity/BFF security flow", () => {
    test.setTimeout(60_000);

    test("login, CSRF, step-up retry binding, terminal close, and logout", async ({
      page,
      request,
      context,
    }) => {
      await request.post(`${mock}/_test/reset`);

      await page.goto(
        `${review}/auth/login?returnTo=${encodeURIComponent(`/internal/review/${snapshotId}/publish`)}`,
      );
      await expect(page).toHaveURL(
        `${review}/internal/review/${snapshotId}/publish`,
      );
      await expect(page.getByText("E2E 검토자")).toBeVisible();
      await expect(
        page.locator('form[data-action-id="publish"]'),
      ).toBeVisible();

      const responseHeaders = await page.request.get(page.url());
      expect(responseHeaders.headers()["cache-control"]).toBe("no-store");
      expect(responseHeaders.headers()["content-security-policy"]).toContain(
        "default-src 'self'",
      );
      expect(responseHeaders.headers()["x-content-type-options"]).toBe(
        "nosniff",
      );

      const sessionCookie = (await context.cookies()).find(
        (cookie) => cookie.name === "gurine_internal_session",
      );
      expect(sessionCookie).toMatchObject({
        httpOnly: true,
        sameSite: "Lax",
        path: "/",
      });
      expect(sessionCookie?.value).toMatch(/^gurine-sc-v1\./);

      const form = page.locator('form[data-action-id="publish"]');
      const initialCsrf = await form
        .locator('input[name="csrfToken"]')
        .inputValue();
      expect(initialCsrf.length).toBeGreaterThanOrEqual(43);
      expect(sessionCookie?.value).not.toContain(initialCsrf);

      const crossOrigin = await page.request.post(
        `${review}/internal/review/${snapshotId}/publish?/publish`,
        {
          headers: {
            origin: "https://attacker.invalid",
            "content-type": "application/x-www-form-urlencoded",
          },
          data: `csrfToken=${encodeURIComponent(initialCsrf)}`,
          maxRedirects: 0,
        },
      );
      expect(crossOrigin.status()).toBe(403);

      const staleCsrf = await page.request.post(
        `${review}/internal/review/${snapshotId}/publish?/publish`,
        {
          headers: { origin: review },
          form: { csrfToken: "stale-token" },
          maxRedirects: 0,
        },
      );
      expect(await staleCsrf.text()).toContain("CSRF_TOKEN_STALE");
      expect((await stateOf(request)).stepUpStartCount).toBe(0);

      await request.post(`${mock}/_test/clear-observations`);
      const stepUpStart = await page.request.post(
        `${review}/internal/review/${snapshotId}/publish?/publish`,
        {
          headers: { origin: review },
          form: {
            csrfToken: initialCsrf,
            caseId,
            reviewSnapshotId: snapshotId,
            previewHash: "b".repeat(64),
            reason: "독립 검토와 게시 gate를 모두 통과했습니다.",
            expectedVersion: "1",
          },
          maxRedirects: 0,
        },
      );
      const stepUpStartText = await stepUpStart.text();
      const redirectResult = JSON.parse(stepUpStartText) as {
        type: string;
        status: number;
        location: string;
      };
      expect(redirectResult).toMatchObject({ type: "redirect", status: 303 });
      const authorizationUrl = redirectResult.location;
      expect(authorizationUrl).toContain("/auth/step-up/callback");
      await page.goto(new URL(authorizationUrl, review).toString());

      await expect(page).toHaveURL(
        new RegExp(`/internal/review/${snapshotId}/publish\\?notice=`),
      );
      await expect(page.getByText("publishCase 완료")).toBeVisible();
      const rotatedCsrf = await page
        .locator('form[data-action-id="publish"] input[name="csrfToken"]')
        .inputValue();
      expect(rotatedCsrf).not.toBe(initialCsrf);

      const state = await stateOf(request);
      expect(state.stepUpStartCount).toBe(1);
      expect(state.stepUpCallbackCount).toBe(1);
      expect(state.authorizationCloseCount).toBe(1);
      expect(state.commandAttempts).toHaveLength(3);
      expect(
        new Set(state.commandAttempts.map((attempt) => attempt.bodySha256))
          .size,
      ).toBe(1);
      expect(
        new Set(
          state.commandAttempts.map((attempt) => attempt.idempotencyKeySha256),
        ).size,
      ).toBe(1);
      expect(
        new Set(
          state.commandAttempts.map((attempt) => attempt.actorAssertionSha256),
        ).size,
      ).toBe(3);
      const publishAssertions = state.assertionOperations.filter(
        (item) => item.operationId === "publishCase",
      );
      expect(publishAssertions).toHaveLength(3);
      expect(
        new Set(publishAssertions.map((item) => item.actorAssertionSha256))
          .size,
      ).toBe(3);

      const cookiesAfterTerminal = await context.cookies();
      expect(
        cookiesAfterTerminal.some(
          (cookie) => cookie.name === "gurine_step_up_transaction",
        ),
      ).toBe(false);
      expect(
        cookiesAfterTerminal.some(
          (cookie) => cookie.name === "gurine_pending_action",
        ),
      ).toBe(false);
      expect(
        cookiesAfterTerminal.some(
          (cookie) => cookie.name === "gurine_step_up_authorization",
        ),
      ).toBe(false);

      await page.request.post(`${review}/auth/logout`, {
        headers: {
          origin: review,
          "content-type": "application/x-www-form-urlencoded",
        },
        data: `csrfToken=${encodeURIComponent(rotatedCsrf)}`,
      });
      const loggedOut = await stateOf(request);
      expect(loggedOut.sessionRevokeCount).toBe(1);
      expect(loggedOut.sessionRevoked).toBe(true);
      expect(
        (await context.cookies()).some(
          (cookie) => cookie.name === "gurine_internal_session",
        ),
      ).toBe(false);
    });
  });

async function stateOf(request: APIRequestContext): Promise<TestState> {
  const response = await request.get(`${mock}/_test/state`);
  expect(response.ok()).toBe(true);
  return (await response.json()) as TestState;
}
