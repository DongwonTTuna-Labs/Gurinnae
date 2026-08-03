import { randomBytes, randomUUID } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  bindSyntheticAbuseProof,
  requiredServerValue,
  serviceAssertionFetch,
} from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import {
  type PrivacyRequestStatusPresentation,
  parsePrivacyRequestStatus,
} from "./privacy-request-status";
import {
  persistPrivacyRequestReceiptSession,
  readSubmissionSession,
} from "./submission-cookie";

type EndpointVerificationProof =
  | Readonly<{ kind: "EMAIL_LINK"; token: string }>
  | Readonly<{ kind: "SMS_OTP"; code: string }>
  | Readonly<{
      kind: "PROVIDER_SIGNED_BINDING";
      provider:
        | "TELEGRAM_BOT_API"
        | "META_WHATSAPP_BUSINESS_CLOUD"
        | "LINE_MESSAGING_API"
        | "SOLAPI_KAKAO_BIZMESSAGE"
        | "TWILIO_VOICE";
      bindingToken: string;
    }>;

export type ServerPrivacyIdentityProof =
  | Readonly<{
      kind: "RESPONSE_RECEIPT";
      receiptId: string;
      possessionToken: string;
    }>
  | Readonly<{
      kind: "VERIFIED_ENDPOINT";
      endpointChallengeId: string;
      endpointProof: EndpointVerificationProof;
    }>;

type PrivacyObjectRef = Readonly<{
  objectType:
    | "RESPONSE"
    | "CORRECTION"
    | "SUBSCRIPTION"
    | "COMMUNICATION_ENDPOINT"
    | "PUBLICATION"
    | "EVIDENCE"
    | "AUDIT_SUBJECT_RECORD";
  objectId: string;
}>;

type PrivacyScope = Readonly<{
  scopeKind: "ALL_VERIFIED_SUBJECT_DATA" | "OBJECT_SET" | "DATE_RANGE";
  objectRefs: readonly PrivacyObjectRef[];
  dateFrom: string | null;
  dateTo: string | null;
  includeDerivatives: boolean;
  includeBackups: boolean;
}>;

type ContactEndpoint =
  | Readonly<{ channel: "EMAIL"; address: string; locale: string }>
  | Readonly<{
      channel: "SMS" | "KAKAO";
      e164: string;
      locale: string;
    }>
  | Readonly<{
      channel: "TELEGRAM" | "WHATSAPP" | "LINE";
      providerSubjectToken: string;
      locale: string;
    }>
  | Readonly<{
      channel: "VOICE";
      e164: string;
      locale: string;
      explicitVoiceConsentReceiptId: string;
    }>;

type AbuseProof = Readonly<{
  provider: "TURNSTILE" | "HCAPTCHA" | "SYNTHETIC_TEST";
  token: string;
  action: string;
  issuedAtEpochSeconds: number | null;
}>;

export type PrivacyRequestCreateInput = Readonly<{
  requestType: "ACCESS" | "CORRECTION" | "DELETION" | "RESTRICTION";
  jurisdiction: string;
  scope: PrivacyScope;
  contactEndpoint: ContactEndpoint;
  statement: string;
  attestation: true;
  privacyConsent: true;
  abuseProof: AbuseProof;
}>;

export type PrivacyRequestBffResult =
  | Readonly<{ ok: true; status: number }>
  | Readonly<{ ok: false; status: number; message: string }>;

export type PrivacyRequestStatusLoad =
  | Readonly<{ state: "ABSENT" }>
  | Readonly<{
      state: "READY";
      status: PrivacyRequestStatusPresentation;
    }>
  | Readonly<{ state: "UNAVAILABLE" }>;

/**
 * Server-only seam: the browser form can supply request details, but the
 * identity proof must come from an independently verified BFF authority. No
 * route may construct it from arbitrary form JSON.
 */
export async function createPrivacyRequestWithServerProof(
  event: RequestEvent,
  input: PrivacyRequestCreateInput,
  subjectIdentityProof: unknown,
  idempotencyKey: string,
): Promise<PrivacyRequestBffResult> {
  if (!acceptedServerPrivacyIdentityProof(subjectIdentityProof))
    return {
      ok: false,
      status: 409,
      message: "신원 확인을 완료한 뒤 개인정보 요청을 제출해 주세요.",
    };
  const body = bindPrivacyAbuseProof({ ...input, subjectIdentityProof });
  const created = await privacyOperation(event, {
    operationId: "createPrivacyRequest",
    body,
    idempotencyKey,
  });
  if (!created.response.ok)
    return failure(
      created.response.status,
      "개인정보 요청을 접수하지 못했습니다.",
    );
  const receiptToken = secretReceiptToken(created.value.receiptToken);
  if (!receiptToken)
    return failure(502, "개인정보 요청 접수 응답을 확인할 수 없습니다.");
  return exchangePrivacyRequestReceipt(event, {
    receiptToken,
    nextSessionToken: randomBytes(32).toString("base64url"),
    idempotencyKey: randomUUID(),
  });
}

function acceptedServerPrivacyIdentityProof(
  value: unknown,
): value is ServerPrivacyIdentityProof {
  const proof = record(value);
  if (!proof) return false;
  if (proof.kind === "RESPONSE_RECEIPT")
    return (
      exactFields(proof, ["kind", "receiptId", "possessionToken"]) &&
      nonemptyString(proof.receiptId) &&
      boundedSecret(proof.possessionToken, 32, 4096)
    );
  if (proof.kind !== "VERIFIED_ENDPOINT") return false;
  const endpointProof = record(proof.endpointProof);
  if (
    !exactFields(proof, ["kind", "endpointChallengeId", "endpointProof"]) ||
    !nonemptyString(proof.endpointChallengeId) ||
    !endpointProof
  )
    return false;
  if (endpointProof.kind === "EMAIL_LINK")
    return (
      exactFields(endpointProof, ["kind", "token"]) &&
      boundedSecret(endpointProof.token, 32, 4096)
    );
  if (endpointProof.kind === "SMS_OTP")
    return (
      exactFields(endpointProof, ["kind", "code"]) &&
      boundedSecret(endpointProof.code, 4, 12)
    );
  return (
    endpointProof.kind === "PROVIDER_SIGNED_BINDING" &&
    exactFields(endpointProof, ["kind", "provider", "bindingToken"]) &&
    privacyProofProvider(endpointProof.provider) &&
    boundedSecret(endpointProof.bindingToken, 32, 4096)
  );
}

function privacyProofProvider(value: unknown): boolean {
  return (
    typeof value === "string" &&
    [
      "TELEGRAM_BOT_API",
      "META_WHATSAPP_BUSINESS_CLOUD",
      "LINE_MESSAGING_API",
      "SOLAPI_KAKAO_BIZMESSAGE",
      "TWILIO_VOICE",
    ].includes(value)
  );
}

function exactFields(
  value: Record<string, unknown>,
  fields: string[],
): boolean {
  const actual = Object.keys(value);
  return (
    actual.length === fields.length &&
    actual.every((field) => fields.includes(field))
  );
}

function nonemptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && !value.includes("\0");
}

function boundedSecret(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum &&
    !value.includes("\0")
  );
}

export async function exchangePrivacyRequestReceipt(
  event: RequestEvent,
  input: Readonly<{
    receiptToken: string;
    nextSessionToken: string;
    idempotencyKey: string;
  }>,
): Promise<PrivacyRequestBffResult> {
  if (
    !secretReceiptToken(input.receiptToken) ||
    !/^[A-Za-z0-9_-]{43}$/u.test(input.nextSessionToken)
  )
    return failure(400, "개인정보 요청 영수증을 확인할 수 없습니다.");
  const exchanged = await privacyOperation(event, {
    operationId: "exchangePrivacyRequestReceiptToken",
    body: { token: input.receiptToken },
    idempotencyKey: input.idempotencyKey,
    nextSessionToken: input.nextSessionToken,
  });
  if (!exchanged.response.ok)
    return failure(
      exchanged.response.status,
      "개인정보 요청 상태 세션을 만들지 못했습니다.",
    );
  if (
    !persistPrivacyRequestReceiptSession(
      event,
      exchanged.value,
      input.nextSessionToken,
    )
  )
    return failure(502, "개인정보 요청 상태 응답을 확인할 수 없습니다.");
  return { ok: true, status: 200 };
}

export async function getPrivacyRequestStatus(
  event: RequestEvent,
): Promise<PrivacyRequestStatusLoad> {
  const session = readSubmissionSession(event);
  if (session?.sessionKind !== "PRIVACY_REQUEST_RECEIPT")
    return { state: "ABSENT" };
  try {
    const result = await privacyOperation(event, {
      operationId: "getPrivacyRequest",
      sessionToken: session.opaqueSessionToken,
    });
    if (!result.response.ok) return { state: "UNAVAILABLE" };
    const status = parsePrivacyRequestStatus(result.value);
    return status ? { state: "READY", status } : { state: "UNAVAILABLE" };
  } catch {
    return { state: "UNAVAILABLE" };
  }
}

type PrivacyOperationInput = Readonly<{
  operationId:
    | "createPrivacyRequest"
    | "exchangePrivacyRequestReceiptToken"
    | "getPrivacyRequest";
  body?: Record<string, unknown>;
  idempotencyKey?: string;
  nextSessionToken?: string;
  sessionToken?: string;
}>;

async function privacyOperation(
  event: RequestEvent,
  input: PrivacyOperationInput,
): Promise<Readonly<{ response: Response; value: Record<string, unknown> }>> {
  const additionalHeaders = {
    ...(input.nextSessionToken
      ? { "x-gurine-next-submission-session": input.nextSessionToken }
      : {}),
    ...(input.sessionToken
      ? { "x-gurine-submission-session": input.sessionToken }
      : {}),
  };
  const result = await invokeSubmissionOperation({
    operationId: input.operationId,
    baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
    fetch: serviceAssertionFetch({
      fetch: event.fetch,
      keyBase64: submissionKey(),
      issuer: "public-web",
      audience: "submission-api",
      ...(Object.keys(additionalHeaders).length > 0
        ? { additionalHeaders }
        : {}),
    }),
    ...(input.body ? { body: input.body } : {}),
    ...(input.idempotencyKey
      ? { headers: { "Idempotency-Key": input.idempotencyKey } }
      : {}),
  });
  return {
    response: result.response ?? new Response(null, { status: 503 }),
    value: record(result.data) ?? record(result.error) ?? {},
  };
}

function submissionKey(): string {
  return requiredServerValue(env, "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT");
}

function bindPrivacyAbuseProof(
  body: Readonly<Record<string, unknown>> &
    Readonly<{ abuseProof: AbuseProof }>,
): Record<string, unknown> {
  if (body.abuseProof.provider !== "SYNTHETIC_TEST") return { ...body };
  const bound = bindSyntheticAbuseProof(
    {
      ...body,
      abuseProof: {
        provider: body.abuseProof.provider,
        token: body.abuseProof.token,
        action: body.abuseProof.action,
        issuedAt: body.abuseProof.issuedAtEpochSeconds,
      },
    },
    {
      action: "createPrivacyRequest",
      keyBase64: submissionKey(),
      siteKey: env.BOT_CHALLENGE_SITE_KEY?.trim(),
    },
  );
  const proof = record(bound.abuseProof);
  if (proof?.provider !== "SYNTHETIC_TEST" || typeof proof.token !== "string")
    throw new Error("privacy abuse proof binding failed");
  return {
    ...body,
    abuseProof: {
      provider: "SYNTHETIC_TEST",
      token: proof.token,
      action: body.abuseProof.action,
      issuedAtEpochSeconds: body.abuseProof.issuedAtEpochSeconds,
    },
  };
}

function secretReceiptToken(value: unknown): string | undefined {
  return typeof value === "string" && value.length >= 32 && value.length <= 4096
    ? value
    : undefined;
}

function failure(status: number, message: string): PrivacyRequestBffResult {
  return { ok: false, status: status >= 400 ? status : 502, message };
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}
