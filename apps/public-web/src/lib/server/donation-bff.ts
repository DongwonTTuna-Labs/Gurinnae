import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { requiredServerValue, serviceAssertionFetch } from "@gurine/config";
import {
  DONATION_CONSENT_NOTICE,
  type DonationActionErrorCode,
  type DonationCadence,
  type DonationFormSelection,
  type DonationOfferViewModel,
  type DonationProvider,
  type DonationQueueReceipt,
} from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import * as v from "valibot";
import { env } from "$env/dynamic/private";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const MAX_JSON_BYTES = 64 * 1024;

const uuid = v.pipe(v.string(), v.regex(UUID_PATTERN), v.uuid());
const sha256 = v.pipe(v.string(), v.regex(SHA256_PATTERN));
const cadence = v.picklist(["ONE_TIME", "RECURRING"]);
const provider = v.picklist(["TOSS_PAYMENTS", "KAKAO_PAY", "STRIPE"]);

const fixtureTierSchema = v.strictObject({
  tierId: uuid,
  amountWholeKrw: v.pipe(
    v.number(),
    v.integer(),
    v.minValue(1),
    v.maxValue(Number.MAX_SAFE_INTEGER),
  ),
});

const fixtureOfferSchema = v.strictObject({
  schemaVersion: v.literal("donation-offer-fixture.v1"),
  authority: v.literal("TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY"),
  offerVersionId: uuid,
  offerDigest: sha256,
  currency: v.literal("KRW"),
  tiers: v.pipe(v.array(fixtureTierSchema), v.minLength(1)),
  cadences: v.tuple([v.literal("ONE_TIME"), v.literal("RECURRING")]),
  providers: v.tuple([
    v.literal("TOSS_PAYMENTS"),
    v.literal("KAKAO_PAY"),
    v.literal("STRIPE"),
  ]),
  productionReadinessEffect: v.literal("NONE"),
});

const queuedReceiptSchema = v.strictObject({
  schemaVersion: v.literal("donation-intent-queued.v1"),
  requestId: uuid,
  jobId: uuid,
  status: v.literal("QUEUED"),
  receiptDigest: sha256,
});

const donationFormSchema = v.strictObject({
  offerVersionId: uuid,
  offerDigest: sha256,
  tierId: uuid,
  cadence,
  provider,
  consent: v.literal("true"),
  idempotencyKey: uuid,
});

export type DonationFormInput = Readonly<{
  offerVersionId: string;
  offerDigest: string;
  tierId: string;
  cadence: DonationCadence;
  provider: DonationProvider;
}>;

export type QueueDonationResult =
  | Readonly<{ ok: true; receipt: DonationQueueReceipt }>
  | Readonly<{
      ok: false;
      status: 400 | 409 | 502 | 503;
      code: DonationActionErrorCode;
    }>;

const unavailableOffer = (): DonationOfferViewModel => ({
  state: "UNAVAILABLE",
  reason: "승인된 테스트 후원 구성이 없어 현재 요청할 수 없습니다.",
});

export async function loadDonationFixtureOffer(
  event: RequestEvent,
): Promise<DonationOfferViewModel> {
  if (env.GURINE_ENV !== "test") return unavailableOffer();
  try {
    const response = await billingGatewayFetch(event)(
      billingGatewayUrl("/internal/v1/donation-offers"),
      { method: "GET", headers: { accept: "application/json" } },
    );
    if (response.status !== 200) return unavailableOffer();
    const value = await boundedJson(response);
    const result = v.safeParse(fixtureOfferSchema, value);
    if (!result.success || hasDuplicateTiers(result.output.tiers)) {
      return unavailableOffer();
    }
    const { schemaVersion: _schemaVersion, ...offer } = result.output;
    return { state: "READY", ...offer };
  } catch {
    return unavailableOffer();
  }
}

export function parseDonationForm(form: FormData): DonationFormInput | null {
  const expected = new Set([
    "offerVersionId",
    "offerDigest",
    "tierId",
    "cadence",
    "provider",
    "consent",
    "idempotencyKey",
  ]);
  const names = [...form.keys()];
  if (
    names.length !== expected.size ||
    names.some((name) => !expected.has(name) || form.getAll(name).length !== 1)
  ) {
    return null;
  }
  const result = v.safeParse(
    donationFormSchema,
    Object.fromEntries(form.entries()),
  );
  if (!result.success) return null;
  return {
    offerVersionId: result.output.offerVersionId,
    offerDigest: result.output.offerDigest,
    tierId: result.output.tierId,
    cadence: result.output.cadence,
    provider: result.output.provider,
  };
}

export function parseDonationFormSelection(
  form: FormData,
): DonationFormSelection | undefined {
  const tierId = singleFormValue(form, "tierId");
  const cadenceValue = singleFormValue(form, "cadence");
  const providerValue = singleFormValue(form, "provider");
  const consentValue = singleFormValue(form, "consent");
  const result = v.safeParse(
    v.strictObject({
      tierId: uuid,
      cadence,
      provider,
      consent: v.literal("true"),
    }),
    {
      tierId,
      cadence: cadenceValue,
      provider: providerValue,
      consent: consentValue,
    },
  );
  if (!result.success) return undefined;
  return {
    tierId: result.output.tierId,
    cadence: result.output.cadence,
    provider: result.output.provider,
    consentAccepted: true,
  };
}

export async function queueDonationIntent(
  event: RequestEvent,
  input: DonationFormInput,
  idempotencyKey: string,
): Promise<QueueDonationResult> {
  if (env.GURINE_ENV !== "test") return unavailableQueue();
  if (!UUID_PATTERN.test(idempotencyKey)) {
    return { ok: false, status: 400, code: "INVALID_REQUEST" };
  }
  const offer = await loadDonationFixtureOffer(event);
  if (offer.state !== "READY") return unavailableQueue();
  if (
    input.offerVersionId !== offer.offerVersionId ||
    input.offerDigest !== offer.offerDigest ||
    !offer.tiers.some((tier) => tier.tierId === input.tierId) ||
    !offer.cadences.includes(input.cadence) ||
    !offer.providers.includes(input.provider)
  ) {
    return { ok: false, status: 409, code: "OFFER_CHANGED" };
  }

  try {
    const requestId = idempotencyKey;
    const request = {
      schemaVersion: "donation-intent-request.v1" as const,
      requestId,
      offerVersionId: offer.offerVersionId,
      offerDigest: offer.offerDigest,
      tierId: input.tierId,
      cadence: input.cadence,
      provider: input.provider,
      consentReceiptDigest: donationConsentReceiptDigest({
        requestId,
        offerVersionId: offer.offerVersionId,
        offerDigest: offer.offerDigest,
        tierId: input.tierId,
        cadence: input.cadence,
        provider: input.provider,
      }),
      paymentAuthorizationToken: requiredServerValue(
        env,
        "DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN",
      ),
    };
    const response = await billingGatewayFetch(event)(
      billingGatewayUrl("/internal/v1/donation-intents"),
      {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "idempotency-key": idempotencyKey,
        },
        body: JSON.stringify(request),
      },
    );
    if (response.status !== 202) return queueFailure(response.status);
    const value = await boundedJson(response);
    const result = v.safeParse(queuedReceiptSchema, value);
    if (!result.success || result.output.requestId !== requestId) {
      return { ok: false, status: 502, code: "UPSTREAM_INVALID" };
    }
    return {
      ok: true,
      receipt: {
        requestId: result.output.requestId,
        jobId: result.output.jobId,
        status: result.output.status,
        receiptDigest: result.output.receiptDigest,
      },
    };
  } catch {
    return unavailableQueue();
  }
}

export function donationConsentReceiptDigest(input: {
  requestId: string;
  offerVersionId: string;
  offerDigest: string;
  tierId: string;
  cadence: DonationCadence;
  provider: DonationProvider;
}): string {
  const preimage = [
    "gurine-donation-consent-receipt.v1",
    input.requestId,
    input.offerVersionId,
    input.offerDigest,
    input.tierId,
    input.cadence,
    input.provider,
    "DONATION-INDEPENDENCE-NOTICE-v1",
    DONATION_CONSENT_NOTICE,
    "ACCEPTED",
  ].join("\n");
  return createHash("sha256").update(preimage, "utf8").digest("hex");
}

function billingGatewayFetch(event: RequestEvent): typeof globalThis.fetch {
  return serviceAssertionFetch({
    fetch: event.fetch,
    keyBase64: requiredServerValue(env, "PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT"),
    issuer: "public-web",
    audience: "billing-gateway",
  });
}

function billingGatewayUrl(path: string): URL {
  return new URL(
    path,
    requiredServerValue(env, "BILLING_GATEWAY_INTERNAL_URL"),
  );
}

async function boundedJson(response: Response): Promise<unknown> {
  if (!response.headers.get("content-type")?.startsWith("application/json")) {
    return null;
  }
  const declaredLength = response.headers.get("content-length");
  if (declaredLength && Number(declaredLength) > MAX_JSON_BYTES) return null;
  const text = await response.text();
  if (Buffer.byteLength(text, "utf8") > MAX_JSON_BYTES) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function hasDuplicateTiers(
  tiers: readonly Readonly<{ tierId: string }>[],
): boolean {
  return new Set(tiers.map((tier) => tier.tierId)).size !== tiers.length;
}

function singleFormValue(
  form: FormData,
  name: string,
): FormDataEntryValue | null {
  const values = form.getAll(name);
  return values.length === 1 ? (values[0] ?? null) : null;
}

function unavailableQueue(): QueueDonationResult {
  return { ok: false, status: 503, code: "UNAVAILABLE" };
}

function queueFailure(status: number): QueueDonationResult {
  if (status === 400 || status === 409) {
    return { ok: false, status, code: "INVALID_REQUEST" };
  }
  if (status === 503) return unavailableQueue();
  return { ok: false, status: 502, code: "UPSTREAM_INVALID" };
}
