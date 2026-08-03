import { describe, expect, it } from "vitest";
import { submitReviewAuthorization } from "./screen-review-authorization";

describe("submitReview authorization branch", () => {
  it("keeps editorial capability while requiring step-up for approval", () => {
    expect(
      submitReviewAuthorization("submitReview", {
        decision: "approve",
        criteria: {},
      }),
    ).toEqual({
      capability: "review.editorial",
      assurance: "STEP_UP",
    });
  });

  it("uses active session for a non-approval editorial decision", () => {
    expect(
      submitReviewAuthorization("submitReview", {
        decision: "changes_required",
        criteria: {},
      }),
    ).toEqual({
      capability: "review.editorial",
      assurance: "ACTIVE_SESSION",
    });
  });

  it("requires the legal capability and step-up for the named-person override", () => {
    expect(
      submitReviewAuthorization("submitReview", {
        decision: "approve",
        criteria: { namedIndividualOverride: {} },
      }),
    ).toEqual({ capability: "review.legal", assurance: "STEP_UP" });
  });

  it("fails closed when the criteria shape cannot prove the ordinary branch", () => {
    for (const body of [undefined, {}, { criteria: null }, { criteria: [] }]) {
      expect(submitReviewAuthorization("submitReview", body)).toEqual({
        capability: "review.legal",
        assurance: "STEP_UP",
      });
    }
  });

  it("does not alter unrelated operation authorization", () => {
    expect(
      submitReviewAuthorization("publishCase", { criteria: {} }),
    ).toBeUndefined();
  });
});
