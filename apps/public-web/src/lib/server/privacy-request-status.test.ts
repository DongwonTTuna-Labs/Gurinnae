import { describe, expect, it } from "vitest";
import { parsePrivacyRequestStatus } from "./privacy-request-status";

const requestId = "11111111-1111-4111-8111-111111111111";
const receiptId = "22222222-2222-4222-8222-222222222222";
const refusalId = "33333333-3333-4333-8333-333333333333";
const digest = "a".repeat(64);

function status(
  overrides: Readonly<Record<string, unknown>> = {},
  requestOverrides: Readonly<Record<string, unknown>> = {},
) {
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
      ...requestOverrides,
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
    ...overrides,
  };
}

describe("privacy request status browser projection", () => {
  it("copies only the bounded status fields and omits receipt identifiers", () => {
    const value = parsePrivacyRequestStatus(status());
    expect(value).toEqual({
      requestType: "ACCESS",
      state: "RECEIVED",
      identityState: "PENDING_VERIFICATION",
      identityVerifiedAt: null,
      dueAt: null,
      updatedAt: "2026-08-01T00:00:00Z",
      nextActionCode: "VERIFY_IDENTITY",
      asOf: "2026-08-01T00:00:00Z",
    });
    expect(JSON.stringify(value)).not.toContain(requestId);
    expect(JSON.stringify(value)).not.toContain(digest);
  });

  it.each([
    ["RECEIVED", "AWAIT_REVIEW"],
    ["REVIEW", "AWAIT_DECISION"],
    ["APPROVED", "AWAIT_EXECUTION"],
  ] as const)("accepts verified %s with its exact next action", (state, action) => {
    expect(
      parsePrivacyRequestStatus(
        status(
          { nextActionCodes: [action] },
          {
            state,
            identityState: "VERIFIED",
            identityVerifiedAt: "2026-08-01T00:00:00Z",
            dueAt: "2026-08-15T00:00:00Z",
          },
        ),
      ),
    ).toMatchObject({ state, nextActionCode: action });
  });

  it("requires terminal decision and refusal receipt pairs", () => {
    expect(
      parsePrivacyRequestStatus(
        status(
          {
            decisionReceiptId: receiptId,
            decisionReceiptSha256: digest,
            nextActionCodes: ["COMPLETE"],
          },
          {
            state: "COMPLETED",
            identityState: "VERIFIED",
            identityVerifiedAt: "2026-08-01T00:00:00Z",
            dueAt: "2026-08-15T00:00:00Z",
          },
        ),
      ),
    ).toMatchObject({ state: "COMPLETED", nextActionCode: "COMPLETE" });

    const rejected = status(
      {
        decisionReceiptId: receiptId,
        decisionReceiptSha256: digest,
        refusalNoticeReceiptId: refusalId,
        refusalNoticeReceiptSha256: digest,
        nextActionCodes: ["REVIEW_REFUSAL_NOTICE"],
      },
      {
        state: "REJECTED",
        identityState: "VERIFIED",
        identityVerifiedAt: "2026-08-01T00:00:00Z",
        dueAt: "2026-08-15T00:00:00Z",
      },
    );
    expect(parsePrivacyRequestStatus(rejected)).toMatchObject({
      state: "REJECTED",
      nextActionCode: "REVIEW_REFUSAL_NOTICE",
    });
    expect(
      parsePrivacyRequestStatus({
        ...rejected,
        refusalNoticeReceiptSha256: null,
      }),
    ).toBeUndefined();
  });

  it.each([
    ["unknown response field", status({ internalReason: "must-not-leak" })],
    ["free-form operation", status({ operationId: "other" })],
    [
      "multiple actions",
      status({ nextActionCodes: ["VERIFY_IDENTITY", "AWAIT_REVIEW"] }),
    ],
    ["mismatched receipt arrays", status({ noticeReceiptIds: [receiptId] })],
    ["pending due date", status({}, { dueAt: "2026-08-15T00:00:00Z" })],
    ["unmapped action", status({ nextActionCodes: ["CALL_SUPPORT"] })],
  ])("fails closed for %s", (_case, value) => {
    expect(parsePrivacyRequestStatus(value)).toBeUndefined();
  });
});
