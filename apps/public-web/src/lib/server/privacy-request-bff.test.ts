import type { RequestEvent } from "@sveltejs/kit";
import { beforeEach, describe, expect, it, vi } from "vitest";

const invokeSubmissionOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  BOT_CHALLENGE_SITE_KEY: "turnstile-site",
  GURINE_ENV: "test",
  PUBLIC_BASE_URL: "http://public-web.test",
  PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT:
    "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s=",
  SUBMISSION_API_INTERNAL_URL: "http://submission-api.test",
  SUBMISSION_COOKIE_KEY_CURRENT: "Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2M=",
}));

vi.mock("@gurine/api-client-submission", () => ({
  invokeSubmissionOperation,
}));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

import {
  createPrivacyRequestWithServerProof,
  exchangePrivacyRequestReceipt,
  getPrivacyRequestStatus,
  type PrivacyRequestCreateInput,
} from "./privacy-request-bff";

const requestId = "11111111-1111-4111-8111-111111111111";
const sessionId = "22222222-2222-4222-8222-222222222222";
const receiptId = "33333333-3333-4333-8333-333333333333";
const digest = "a".repeat(64);
const receiptToken = `receipt-${"r".repeat(40)}`;
const nextSessionToken = "N".repeat(43);

type CookieWrite = Readonly<{
  name: string;
  value: string;
  options: Record<string, unknown>;
}>;

function requestEvent() {
  const values = new Map<string, string>();
  const writes: CookieWrite[] = [];
  const requests: Request[] = [];
  const fetch = vi.fn(
    async (request: RequestInfo | URL, init?: RequestInit) => {
      const value =
        request instanceof Request ? request : new Request(request, init);
      requests.push(value);
      return new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  );
  const url = new URL("http://public-web.test/privacy");
  const event = {
    cookies: {
      get: (name: string) => values.get(name),
      set: (name: string, value: string, options: Record<string, unknown>) => {
        values.set(name, value);
        writes.push({ name, value, options });
      },
      delete: (name: string) => values.delete(name),
    },
    fetch,
    params: {},
    request: new Request(url),
    url,
  } as unknown as RequestEvent;
  return { event, requests, values, writes };
}

function createInput(): PrivacyRequestCreateInput {
  return {
    requestType: "ACCESS",
    jurisdiction: "KR",
    scope: {
      scopeKind: "ALL_VERIFIED_SUBJECT_DATA",
      objectRefs: [],
      dateFrom: null,
      dateTo: null,
      includeDerivatives: true,
      includeBackups: true,
    },
    contactEndpoint: {
      channel: "EMAIL",
      address: "reader@example.test",
      locale: "ko-KR",
    },
    statement: "보유 개인정보 열람 요청",
    attestation: true,
    privacyConsent: true,
    abuseProof: {
      provider: "TURNSTILE",
      token: "turnstile-proof",
      action: "createPrivacyRequest",
      issuedAtEpochSeconds: null,
    },
  };
}

function exchangeReceipt() {
  return {
    requestId,
    sessionId,
    state: "ACTIVE",
    expiresAt: "2099-08-01T01:00:00Z",
    cookieName: "gurine_privacy_request_receipt_session",
    tokenConsumedAt: "2026-08-01T00:00:00Z",
  };
}

function publicStatus() {
  return {
    request: {
      privacyRequestId: requestId,
      requestType: "ACCESS",
      state: "RECEIVED",
      jurisdiction: "KR",
      scopeDigest: digest,
      identityState: "PENDING_VERIFICATION",
      identityVerifiedAt: null,
      dueAt: null,
      createdAt: "2026-08-01T00:00:00Z",
      updatedAt: "2026-08-01T00:00:00Z",
    },
    decisionReasonCode: null,
    decisionReceiptId: null,
    decisionReceiptSha256: null,
    refusalNoticeReceiptId: null,
    refusalNoticeReceiptSha256: null,
    noticeReceiptIds: [],
    noticeReceiptSha256s: [],
    nextActionCodes: ["VERIFY_IDENTITY"],
    asOf: "2026-08-01T00:00:00Z",
    links: [],
    operationId: "getPrivacyRequest",
  };
}

async function dispatchGeneratedRequest(input: Record<string, unknown>) {
  const operationId = String(input.operationId);
  const fetch = input.fetch as typeof globalThis.fetch;
  const body = input.body as Record<string, unknown> | undefined;
  const headers = new Headers(
    (input.headers as Record<string, string> | undefined) ?? {},
  );
  const method = operationId === "getPrivacyRequest" ? "GET" : "POST";
  if (body) headers.set("content-type", "application/json");
  const path =
    operationId === "createPrivacyRequest"
      ? "/v1/privacy-requests"
      : operationId === "exchangePrivacyRequestReceiptToken"
        ? "/v1/submission-session/privacy-request-receipt:exchange"
        : "/v1/privacy-request-receipt";
  await fetch(
    new Request(`http://submission-api.test${path}`, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    }),
  );
}

beforeEach(() => {
  invokeSubmissionOperation.mockReset();
  invokeSubmissionOperation.mockImplementation(async (unknownInput) => {
    const input = unknownInput as Record<string, unknown>;
    await dispatchGeneratedRequest(input);
    const operationId = String(input.operationId);
    if (operationId === "createPrivacyRequest")
      return {
        data: {
          command: { aggregateId: receiptId },
          request: { privacyRequestId: requestId },
          receiptToken,
        },
        response: new Response(null, { status: 201 }),
      };
    if (operationId === "exchangePrivacyRequestReceiptToken")
      return {
        data: exchangeReceipt(),
        response: new Response(null, { status: 200 }),
      };
    return {
      data: publicStatus(),
      response: new Response(null, { status: 200 }),
    };
  });
});

describe("privacy request public-web BFF", () => {
  it("fails closed before any API call when the server-only identity proof is absent", async () => {
    const { event } = requestEvent();
    await expect(
      createPrivacyRequestWithServerProof(
        event,
        createInput(),
        undefined,
        "privacy-create-0001",
      ),
    ).resolves.toEqual({
      ok: false,
      status: 409,
      message: "신원 확인을 완료한 뒤 개인정보 요청을 제출해 주세요.",
    });
    expect(invokeSubmissionOperation).not.toHaveBeenCalled();
  });

  it("rejects the producerless identity document challenge before any API call", async () => {
    const { event } = requestEvent();
    await expect(
      createPrivacyRequestWithServerProof(
        event,
        createInput(),
        {
          kind: "IDENTITY_DOCUMENT_CHALLENGE",
          challengeId: receiptId,
          verificationReceiptId: requestId,
          verificationReceiptDigest: digest,
        },
        "privacy-create-document-proof",
      ),
    ).resolves.toEqual({
      ok: false,
      status: 409,
      message: "신원 확인을 완료한 뒤 개인정보 요청을 제출해 주세요.",
    });
    expect(invokeSubmissionOperation).not.toHaveBeenCalled();
  });

  it("creates and exchanges entirely server-side without returning either raw token", async () => {
    const { event, requests, writes } = requestEvent();
    const result = await createPrivacyRequestWithServerProof(
      event,
      createInput(),
      {
        kind: "RESPONSE_RECEIPT",
        receiptId,
        possessionToken: "P".repeat(43),
      },
      "privacy-create-0001",
    );

    expect(result).toEqual({ ok: true, status: 200 });
    expect(JSON.stringify(result)).not.toContain(receiptToken);
    expect(JSON.stringify(result)).not.toContain(nextSessionToken);
    expect(invokeSubmissionOperation).toHaveBeenCalledTimes(2);
    expect(invokeSubmissionOperation.mock.calls[1]?.[0]).toMatchObject({
      operationId: "exchangePrivacyRequestReceiptToken",
      body: { token: receiptToken },
    });

    const exchange = requests[1];
    expect(exchange?.headers.get("x-gurine-next-submission-session")).toMatch(
      /^[A-Za-z0-9_-]{43}$/u,
    );
    expect(exchange?.headers.get("x-gurine-submission-session")).toBeNull();
    expect(exchange?.headers.get("cookie")).toBeNull();
    expect(exchange?.headers.get("x-gurine-service-assertion")).toContain(
      "gurine-sa-v1.",
    );
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({
      name: "gurine_privacy_request_receipt_session",
      options: {
        path: "/privacy",
        httpOnly: true,
        sameSite: "lax",
      },
    });
    expect(writes[0]?.value).not.toContain(receiptToken);
    expect(writes[0]?.value).not.toContain(
      exchange?.headers.get("x-gurine-next-submission-session") ?? "",
    );
  });

  it("seals the retained next token only after an exact successful receipt", async () => {
    const { event, writes } = requestEvent();
    invokeSubmissionOperation.mockImplementationOnce(async (unknownInput) => {
      await dispatchGeneratedRequest(unknownInput as Record<string, unknown>);
      return {
        data: { ...exchangeReceipt(), cookieName: "unexpected_cookie" },
        response: new Response(null, { status: 200 }),
      };
    });
    const result = await exchangePrivacyRequestReceipt(event, {
      receiptToken,
      nextSessionToken,
      idempotencyKey: "privacy-exchange-0001",
    });
    expect(result).toEqual({
      ok: false,
      status: 502,
      message: "개인정보 요청 상태 응답을 확인할 수 없습니다.",
    });
    expect(writes).toEqual([]);
  });

  it("opens the sealed scoped token for status GET and projects no receipts", async () => {
    const { event, requests } = requestEvent();
    await expect(
      exchangePrivacyRequestReceipt(event, {
        receiptToken,
        nextSessionToken,
        idempotencyKey: "privacy-exchange-0001",
      }),
    ).resolves.toEqual({ ok: true, status: 200 });
    requests.length = 0;
    const result = await getPrivacyRequestStatus(event);
    expect(result).toMatchObject({
      state: "READY",
      status: {
        state: "RECEIVED",
        nextActionCode: "VERIFY_IDENTITY",
      },
    });
    expect(JSON.stringify(result)).not.toContain(requestId);
    expect(JSON.stringify(result)).not.toContain(digest);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.headers.get("x-gurine-submission-session")).toBe(
      nextSessionToken,
    );
    expect(
      requests[0]?.headers.get("x-gurine-next-submission-session"),
    ).toBeNull();
  });
});
