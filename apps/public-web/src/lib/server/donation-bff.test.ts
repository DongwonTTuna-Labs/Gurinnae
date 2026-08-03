import { createHash } from "node:crypto";
import type { RequestEvent } from "@sveltejs/kit";
import { beforeEach, describe, expect, it, vi } from "vitest";

const privateEnv = vi.hoisted(() => ({
  BILLING_GATEWAY_INTERNAL_URL: "http://billing-gateway.test",
  DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN: "fixture-payment-token-secret",
  GURINE_ENV: "test",
  PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT:
    "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s=",
}));

vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

import {
  donationConsentReceiptDigest,
  loadDonationFixtureOffer,
  parseDonationForm,
  parseDonationFormSelection,
  queueDonationIntent,
} from "./donation-bff";

const offerVersionId = "11111111-1111-4111-8111-111111111111";
const tierId = "22222222-2222-4222-8222-222222222222";
const requestId = "33333333-3333-4333-8333-333333333333";
const jobId = "44444444-4444-4444-8444-444444444444";
const offerDigest = "a".repeat(64);
const receiptDigest = "b".repeat(64);

function fixtureOffer(extra: Record<string, unknown> = {}) {
  return {
    schemaVersion: "donation-offer-fixture.v1",
    authority: "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY",
    offerVersionId,
    offerDigest,
    currency: "KRW",
    tiers: [{ tierId, amountWholeKrw: 10_000 }],
    cadences: ["ONE_TIME", "RECURRING"],
    providers: ["TOSS_PAYMENTS", "KAKAO_PAY", "STRIPE"],
    productionReadinessEffect: "NONE",
    ...extra,
  };
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function requestEvent(
  handler: (request: Request) => Response | Promise<Response>,
) {
  const requests: Request[] = [];
  const fetch = vi.fn(
    async (resource: RequestInfo | URL, init?: RequestInit) => {
      const request =
        resource instanceof Request ? resource : new Request(resource, init);
      requests.push(request);
      return handler(request);
    },
  );
  return {
    event: { fetch } as unknown as RequestEvent,
    requests,
  };
}

function validForm(extra?: readonly [string, string]): FormData {
  const form = new FormData();
  form.set("offerVersionId", offerVersionId);
  form.set("offerDigest", offerDigest);
  form.set("tierId", tierId);
  form.set("cadence", "RECURRING");
  form.set("provider", "TOSS_PAYMENTS");
  form.set("consent", "true");
  form.set("idempotencyKey", requestId);
  if (extra) form.set(extra[0], extra[1]);
  return form;
}

beforeEach(() => {
  privateEnv.GURINE_ENV = "test";
  privateEnv.DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN =
    "fixture-payment-token-secret";
});

describe("donation billing BFF", () => {
  it("loads only the signed TEST_FIXTURE offer without copying tier values", async () => {
    const { event, requests } = requestEvent(() => json(fixtureOffer()));

    await expect(loadDonationFixtureOffer(event)).resolves.toMatchObject({
      state: "READY",
      authority: "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY",
      tiers: [{ tierId, amountWholeKrw: 10_000 }],
      productionReadinessEffect: "NONE",
    });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe(
      "http://billing-gateway.test/internal/v1/donation-offers",
    );
    expect(requests[0]?.headers.get("x-gurine-service-assertion")).toBeTruthy();
  });

  it("fails closed for production, malformed or duplicate fixture authority", async () => {
    const production = requestEvent(() => {
      throw new Error("must not fetch");
    });
    privateEnv.GURINE_ENV = "production";
    await expect(loadDonationFixtureOffer(production.event)).resolves.toEqual({
      state: "UNAVAILABLE",
      reason: "승인된 테스트 후원 구성이 없어 현재 요청할 수 없습니다.",
    });
    expect(production.requests).toHaveLength(0);

    privateEnv.GURINE_ENV = "test";
    const malformed = requestEvent(() =>
      json(fixtureOffer({ unexpectedProductionTier: 50_000 })),
    );
    await expect(
      loadDonationFixtureOffer(malformed.event),
    ).resolves.toMatchObject({ state: "UNAVAILABLE" });
    const duplicate = requestEvent(() =>
      json(
        fixtureOffer({
          tiers: [
            { tierId, amountWholeKrw: 10_000 },
            { tierId, amountWholeKrw: 20_000 },
          ],
        }),
      ),
    );
    await expect(
      loadDonationFixtureOffer(duplicate.event),
    ).resolves.toMatchObject({ state: "UNAVAILABLE" });
  });

  it("strictly parses browser fields and never accepts a browser token", () => {
    expect(parseDonationForm(validForm())).toEqual({
      offerVersionId,
      offerDigest,
      tierId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
    });
    expect(
      parseDonationForm(
        validForm(["paymentAuthorizationToken", "browser-secret"]),
      ),
    ).toBeNull();
    const missingConsent = validForm();
    missingConsent.delete("consent");
    expect(parseDonationForm(missingConsent)).toBeNull();
    expect(parseDonationFormSelection(validForm())).toEqual({
      tierId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
      consentAccepted: true,
    });
    expect(
      parseDonationFormSelection(
        validForm(["paymentAuthorizationToken", "browser-secret"]),
      ),
    ).toEqual({
      tierId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
      consentAccepted: true,
    });
    expect(parseDonationFormSelection(missingConsent)).toBeUndefined();
  });

  it("binds consent and queues one signed request without returning the token", async () => {
    const { event, requests } = requestEvent(async (request) => {
      if (request.method === "GET") return json(fixtureOffer());
      const body = (await request.clone().json()) as Record<string, unknown>;
      return json(
        {
          schemaVersion: "donation-intent-queued.v1",
          requestId: body.requestId,
          jobId,
          status: "QUEUED",
          receiptDigest,
        },
        202,
      );
    });
    const input = parseDonationForm(validForm());
    if (!input) throw new Error("fixture form must parse");

    const result = await queueDonationIntent(event, input, requestId);

    expect(result).toEqual({
      ok: true,
      receipt: { requestId, jobId, status: "QUEUED", receiptDigest },
    });
    expect(requests).toHaveLength(2);
    const queued = requests[1];
    if (!queued) throw new Error("queue request is missing");
    const body = (await queued.clone().json()) as Record<string, unknown>;
    expect(queued.headers.get("idempotency-key")).toBe(requestId);
    expect(queued.headers.get("x-gurine-service-assertion")).toBeTruthy();
    expect(body).toMatchObject({
      schemaVersion: "donation-intent-request.v1",
      requestId,
      offerVersionId,
      offerDigest,
      tierId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
      paymentAuthorizationToken: "fixture-payment-token-secret",
    });
    expect(body.consentReceiptDigest).toBe(
      donationConsentReceiptDigest({
        requestId,
        offerVersionId,
        offerDigest,
        tierId,
        cadence: "RECURRING",
        provider: "TOSS_PAYMENTS",
      }),
    );
    expect(JSON.stringify(result)).not.toContain(
      "fixture-payment-token-secret",
    );
  });

  it("uses the exact LF consent preimage", () => {
    const preimage = [
      "gurine-donation-consent-receipt.v1",
      requestId,
      offerVersionId,
      offerDigest,
      tierId,
      "RECURRING",
      "TOSS_PAYMENTS",
      "DONATION-INDEPENDENCE-NOTICE-v1",
      "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
      "ACCEPTED",
    ].join("\n");
    expect(
      donationConsentReceiptDigest({
        requestId,
        offerVersionId,
        offerDigest,
        tierId,
        cadence: "RECURRING",
        provider: "TOSS_PAYMENTS",
      }),
    ).toBe(createHash("sha256").update(preimage, "utf8").digest("hex"));
  });

  it("does not claim success for an invalid queue receipt", async () => {
    const { event } = requestEvent(async (request) => {
      if (request.method === "GET") return json(fixtureOffer());
      const body = (await request.clone().json()) as Record<string, unknown>;
      return json(
        {
          schemaVersion: "donation-intent-queued.v1",
          requestId: body.requestId,
          jobId,
          status: "PAID",
          receiptDigest,
        },
        202,
      );
    });
    const input = parseDonationForm(validForm());
    if (!input) throw new Error("fixture form must parse");
    await expect(queueDonationIntent(event, input, requestId)).resolves.toEqual(
      { ok: false, status: 502, code: "UPSTREAM_INVALID" },
    );
  });
});
