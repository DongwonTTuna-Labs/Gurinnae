import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  DONATION_FIXTURE_OFFER,
  DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
  handleDonationMock,
  validatePrivateDonationMockContract,
} from "./mock-api-donation";
import { handleMockRequest } from "./mock-api-routes";

const origin = "http://mock.test";
const requestId = "33333333-3333-4333-8333-333333333333";

function queueRequest(extra: Record<string, unknown> = {}): Request {
  const tier = DONATION_FIXTURE_OFFER.tiers[0];
  if (!tier) throw new Error("donation TEST_FIXTURE tier is missing");
  const consentReceiptDigest = createHash("sha256")
    .update(
      [
        "gurine-donation-consent-receipt.v1",
        requestId,
        DONATION_FIXTURE_OFFER.offerVersionId,
        DONATION_FIXTURE_OFFER.offerDigest,
        tier.tierId,
        "RECURRING",
        "TOSS_PAYMENTS",
        "DONATION-INDEPENDENCE-NOTICE-v1",
        "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
        "ACCEPTED",
      ].join("\n"),
    )
    .digest("hex");
  return new Request(`${origin}/internal/v1/donation-intents`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "idempotency-key": requestId,
      "x-gurine-service-assertion": "gurine-sa-v1.TEST_ONLY",
      "x-request-id": requestId,
    },
    body: JSON.stringify({
      schemaVersion: "donation-intent-request.v1",
      requestId,
      offerVersionId: DONATION_FIXTURE_OFFER.offerVersionId,
      offerDigest: DONATION_FIXTURE_OFFER.offerDigest,
      tierId: tier.tierId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
      consentReceiptDigest,
      paymentAuthorizationToken: DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
      ...extra,
    }),
  });
}

describe("R6e donation private mock", () => {
  it("serves only an explicit TEST_FIXTURE offer in test mode", async () => {
    const request = new Request(`${origin}/internal/v1/donation-offers`);
    const response = await handleDonationMock(
      request,
      new URL(request.url),
      "test",
      DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
    );
    expect(response?.status).toBe(200);
    const body: unknown = await response?.clone().json();
    expect(body).toEqual(DONATION_FIXTURE_OFFER);
    expect(body).toMatchObject({
      authority: "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY",
      productionReadinessEffect: "NONE",
    });
    await expect(
      response
        ? validatePrivateDonationMockContract(request, response)
        : undefined,
    ).resolves.toMatchObject({ ok: true });
  });

  it("fails closed outside test mode without leaking fixture tiers", async () => {
    const request = new Request(`${origin}/internal/v1/donation-offers`);
    const response = await handleDonationMock(
      request,
      new URL(request.url),
      "production",
      DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
    );
    expect(response?.status).toBe(503);
    const text = await response?.clone().text();
    expect(text).not.toContain("amountWholeKrw");
    expect(text).not.toContain("tiers");
    await expect(
      response
        ? validatePrivateDonationMockContract(request, response)
        : undefined,
    ).resolves.toMatchObject({ ok: true });

    const missingTestConfig = await handleDonationMock(
      request,
      new URL(request.url),
      "test",
      "wrong-test-token",
    );
    expect(missingTestConfig?.status).toBe(503);
    expect(await missingTestConfig?.text()).not.toContain("amountWholeKrw");
  });

  it("returns only a bound QUEUED receipt and consumes no browser-visible token", async () => {
    const request = queueRequest();
    const response = await handleDonationMock(
      request,
      new URL(request.url),
      "test",
      DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
    );
    expect(response?.status).toBe(202);
    const text = await response?.clone().text();
    expect(text).toContain('"status":"QUEUED"');
    expect(text).not.toContain(DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN);
    expect(text).not.toMatch(/PAID|CHARGED|paymentSuccess/u);
    await expect(
      response
        ? validatePrivateDonationMockContract(request, response)
        : undefined,
    ).resolves.toMatchObject({ ok: true });
  });

  it("rejects changed request shape and changed success receipt shape", async () => {
    const changedRequest = queueRequest({ browserExtra: "forbidden" });
    const failure = await handleDonationMock(
      changedRequest,
      new URL(changedRequest.url),
      "test",
      DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
    );
    expect(failure?.status).toBe(400);

    const validRequest = queueRequest();
    const invalidReceipt = Response.json(
      {
        schemaVersion: "donation-intent-queued.v1",
        requestId,
        jobId: "44444444-4444-4444-8444-444444444444",
        status: "QUEUED",
        receiptDigest: "a".repeat(64),
        paymentAuthorizationToken: "private",
      },
      { status: 202 },
    );
    await expect(
      validatePrivateDonationMockContract(validRequest, invalidReceipt),
    ).resolves.toMatchObject({ ok: false });
  });

  it("keeps service assertion denial inside the exact private contract", async () => {
    const response = await handleMockRequest(
      new Request(`${origin}/internal/v1/donation-offers`),
    );
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({
      code: "SERVICE_ASSERTION_REQUIRED",
    });
  });
});
