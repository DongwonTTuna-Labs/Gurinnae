import { describe, expect, it } from "vitest";
import {
  isSubmissionSessionPayload,
  type SubmissionSessionPayload,
  submissionCookieForKind,
  submissionCookiesForPath,
  submissionSessionKinds,
} from "./submission-session";

const privacyCookie = {
  name: "gurine_privacy_request_receipt_session",
  path: "/privacy",
  kinds: ["PRIVACY_REQUEST_RECEIPT"],
} as const;

const privacyPayload: SubmissionSessionPayload = {
  v: 1,
  typ: "submission-session",
  sessionKind: "PRIVACY_REQUEST_RECEIPT",
  opaqueSessionToken: "A".repeat(43),
  csrfToken: "B".repeat(43),
  issuedAt: 1_783_828_800,
  absoluteExpiresAt: 1_783_832_400,
  csrfRotatedAt: 1_783_828_800,
};

describe("privacy request receipt submission session", () => {
  it("extends the closed kind registry without replacing existing kinds", () => {
    expect(submissionSessionKinds).toEqual([
      "RESPONSE_PENDING",
      "RESPONSE_ACTIVE",
      "CORRECTION_DRAFT",
      "SUBSCRIPTION_PENDING",
      "SUBSCRIPTION_MANAGEMENT",
      "RESPONSE_RECEIPT",
      "CORRECTION_RECEIPT",
      "PRIVACY_REQUEST_RECEIPT",
    ]);
  });

  it("maps the privacy receipt kind to its exact cookie profile", () => {
    expect(submissionCookieForKind("PRIVACY_REQUEST_RECEIPT")).toEqual(
      privacyCookie,
    );
  });

  it("filters the privacy cookie on its path boundary only", () => {
    expect(submissionCookiesForPath("/privacy")).toEqual([privacyCookie]);
    expect(submissionCookiesForPath("/privacy/request")).toEqual([
      privacyCookie,
    ]);
    expect(submissionCookiesForPath("/privacy-policy")).toEqual([]);
  });

  it("accepts the privacy receipt payload and rejects unknown kinds", () => {
    expect(isSubmissionSessionPayload(privacyPayload)).toBe(true);
    expect(
      isSubmissionSessionPayload({
        ...privacyPayload,
        sessionKind: "PRIVACY_REQUEST",
      }),
    ).toBe(false);
  });
});
