import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DONATION_CONSENT_NOTICE,
  DONATION_INDEPENDENCE_NOTICE,
  donationActionErrorMessage,
  donationActionState,
  donationAmountLabel,
  donationCadenceLabel,
  donationFormSelection,
  donationProviderLabel,
  donationReceiptStatusLabel,
} from "./donation";

const requestId = "11111111-1111-4111-8111-111111111111";
const jobId = "22222222-2222-4222-8222-222222222222";
const receiptDigest = "a".repeat(64);
const donationForm = readFileSync(
  new URL("./components/sections/PublicDonationForm.svelte", import.meta.url),
  "utf8",
);
const donationSummary = readFileSync(
  new URL(
    "./components/sections/PublicDonationSummary.svelte",
    import.meta.url,
  ),
  "utf8",
);
const donationReceipt = readFileSync(
  new URL(
    "./components/sections/PublicDonationReceipt.svelte",
    import.meta.url,
  ),
  "utf8",
);

describe("donation presentation", () => {
  it("accepts only a closed queued receipt", () => {
    expect(
      donationActionState({
        donationAction: {
          state: "QUEUED",
          receipt: {
            requestId,
            jobId,
            status: "QUEUED",
            receiptDigest,
            paymentAuthorizationToken: "must-not-cross-the-boundary",
          },
        },
      }),
    ).toEqual({
      state: "QUEUED",
      receipt: { requestId, jobId, status: "QUEUED", receiptDigest },
    });
  });

  it("fails closed for malformed or provider-claimed completion", () => {
    expect(donationActionState(undefined)).toEqual({ state: "IDLE" });
    expect(
      donationActionState({
        donationAction: {
          state: "QUEUED",
          receipt: { requestId, jobId, status: "PAID", receiptDigest },
        },
      }),
    ).toEqual({ state: "ERROR", code: "UPSTREAM_INVALID" });
    expect(
      donationActionState({
        donationAction: { state: "ERROR", code: "PROVIDER_BODY" },
      }),
    ).toEqual({ state: "ERROR", code: "UPSTREAM_INVALID" });
  });

  it("restores only a closed safe selection after an action error", () => {
    const selection = {
      tierId: jobId,
      cadence: "RECURRING",
      provider: "TOSS_PAYMENTS",
      consentAccepted: true,
    } as const;
    expect(donationFormSelection(selection)).toEqual(selection);
    expect(
      donationActionState({
        donationAction: { state: "ERROR", code: "OFFER_CHANGED" },
        donationSelection: selection,
      }),
    ).toEqual({
      state: "ERROR",
      code: "OFFER_CHANGED",
      selection,
    });
    expect(
      donationFormSelection({ ...selection, paymentAuthorizationToken: "x" }),
    ).toBeUndefined();
  });

  it("uses the binding notices and labels without inventing tier values", () => {
    expect(DONATION_INDEPENDENCE_NOTICE).toBe(
      "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
    );
    expect(DONATION_CONSENT_NOTICE).toBe(
      "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
    );
    expect(donationAmountLabel(12_345)).toContain("12,345");
    expect(donationCadenceLabel("RECURRING")).toBe("정기 후원");
    expect(donationProviderLabel("TOSS_PAYMENTS")).toBe("토스페이먼츠");
    expect(donationReceiptStatusLabel("QUEUED")).toBe("접수 대기");
  });

  it("maps only closed error codes to safe copy", () => {
    expect(donationActionErrorMessage("UNAVAILABLE")).not.toContain("provider");
  });

  it("presents fixture-only authority without internal tokens", () => {
    const presentation = `${donationForm}\n${donationSummary}\n${donationReceipt}`;
    expect(presentation).not.toContain(
      "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY",
    );
    expect(presentation).not.toContain(">TEST MODE<");
    expect(presentation).not.toContain(">NONE<");
    expect(presentation).not.toContain(">TEST_FIXTURE<");
    expect(donationReceipt).not.toContain("QUEUED는");
    expect(donationReceipt).not.toContain("provider 재조회");
    expect(donationReceipt).not.toContain(">영수증 digest<");
    expect(donationSummary).toContain(
      "테스트 픽스처 전용 · 운영 금액 기준 없음",
    );
    expect(donationSummary).toContain("테스트 모드 · 운영 사용 불가");
  });

  it("binds validation errors and focuses each queued receipt once", () => {
    expect(donationForm).toContain('id="donation-form-error-summary"');
    expect(donationForm).toContain("aria-describedby={inputDescriptionIds}");
    expect(donationForm).toContain(
      'aria-invalid={hasValidationError ? "true" : undefined}',
    );
    expect(donationReceipt).toContain("receiptId === focusedReceiptId");
    expect(donationReceipt).toContain("focusedReceiptId = receiptId");
    expect(donationReceipt).toContain("receiptHeading?.focus()");
    expect(donationReceipt).toContain('tabindex="-1"');
  });
});
