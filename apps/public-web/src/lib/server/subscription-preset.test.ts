import { describe, expect, it } from "vitest";
import {
  caseSubscriptionReturnTo,
  handle__j01__create_subscription_verification_receipt_v1,
  route__j01__return_after_subscription_v1,
  subscriptionPreset,
  subscriptionQuery,
} from "./subscription-preset";

describe("subscription scope presets", () => {
  it("binds record subscriptions to the route rather than a browser field", () => {
    expect(
      subscriptionPreset(
        { scope_type: "CASE" },
        new URL("https://public.example/cases/case-a"),
        { caseSlug: "case-a" },
      ),
    ).toEqual({ scope_type: "CASE", scope_ref: "case-a" });
    expect(() =>
      subscriptionPreset(
        { scope_type: "AGENCY" },
        new URL("https://public.example/agencies"),
        {},
      ),
    ).toThrow("agencySlug");
  });

  it("captures a stable cursor-free query subscription", () => {
    const query = subscriptionQuery(
      new URL(
        "https://public.example/cases?publicationState=OPEN&publicationState=CORRECTED&q=contract&sort=title_asc&cursor=secret&notice=done",
      ),
    );
    expect(query).toEqual({
      route: "/cases",
      search: "contract",
      filters: [
        {
          name: "publicationState",
          values: ["CORRECTED", "OPEN"],
        },
      ],
      sort: "title_asc",
    });
  });

  it("accepts only closed server-transported contextual presets", () => {
    const query = encodeURIComponent(
      JSON.stringify({
        route: "/cases",
        filters: [
          { name: "publicationState", values: ["PUBLISHED_EXPLAINED"] },
        ],
        sort: "updated_desc",
      }),
    );
    expect(
      subscriptionPreset(
        {},
        new URL(`https://public.example/subscribe?scope=QUERY&query=${query}`),
        {},
      ),
    ).toEqual({
      scope_type: "QUERY",
      query: {
        route: "/cases",
        filters: [
          { name: "publicationState", values: ["PUBLISHED_EXPLAINED"] },
        ],
        sort: "updated_desc",
      },
    });
    expect(
      subscriptionPreset(
        {},
        new URL("https://public.example/subscribe?scope=CASE&ref=case-a"),
        {},
      ),
    ).toEqual({ scope_type: "CASE", scope_ref: "case-a" });
    expect(
      subscriptionPreset(
        {},
        new URL("https://public.example/subscribe?scope=CASE&ref=../internal"),
        {},
      ),
    ).toEqual({});
  });

  it("rejects undeclared query snapshot fields and filter names", () => {
    for (const snapshot of [
      {
        route: "/internal/cases",
        filters: [],
        sort: "updated_desc",
      },
      {
        route: "/cases",
        filters: [{ name: "cursor", values: ["secret"] }],
        sort: "updated_desc",
      },
    ]) {
      const url = new URL("https://public.example/subscribe");
      url.searchParams.set("scope", "QUERY");
      url.searchParams.set("query", JSON.stringify(snapshot));
      expect(subscriptionPreset({}, url, {})).toEqual({});
    }
  });

  it("accepts REGION only with an exact five-digit sigungu code", () => {
    expect(
      subscriptionPreset(
        {},
        new URL("https://public.example/subscribe?scope=REGION&ref=11680"),
        {},
      ),
    ).toEqual({ scope_type: "REGION", scope_ref: "11680" });

    for (const ref of ["11", "1168A", "116800", "../internal"]) {
      expect(
        subscriptionPreset(
          {},
          new URL(
            `https://public.example/subscribe?scope=REGION&ref=${encodeURIComponent(ref)}`,
          ),
          {},
        ),
      ).toEqual({});
    }
  });

  it("closes a transported query snapshot over the two region codes", () => {
    const url = new URL("https://public.example/subscribe");
    url.searchParams.set("scope", "QUERY");
    url.searchParams.set(
      "query",
      JSON.stringify({
        route: "/cases",
        filters: [
          { name: "sidoCode", values: ["11"] },
          { name: "sigunguCode", values: ["11680"] },
        ],
        sort: "updated_desc",
      }),
    );

    expect(subscriptionPreset({}, url, {})).toEqual({
      scope_type: "QUERY",
      query: {
        route: "/cases",
        filters: [
          { name: "sidoCode", values: ["11"] },
          { name: "sigunguCode", values: ["11680"] },
        ],
        sort: "updated_desc",
      },
    });
  });

  it("rejects malformed or mutually inconsistent region query codes", () => {
    for (const filters of [
      [{ name: "sidoCode", values: ["1A"] }],
      [{ name: "sidoCode", values: ["11", "26"] }],
      [{ name: "sigunguCode", values: ["1168"] }],
      [
        { name: "sidoCode", values: ["26"] },
        { name: "sigunguCode", values: ["11680"] },
      ],
    ]) {
      const url = new URL("https://public.example/subscribe");
      url.searchParams.set("scope", "QUERY");
      url.searchParams.set(
        "query",
        JSON.stringify({ route: "/cases", filters, sort: "updated_desc" }),
      );
      expect(subscriptionPreset({}, url, {})).toEqual({});
    }
  });

  it("accepts only a canonical source route bound to the submitted case", () => {
    const casePayload = { scopeType: "CASE", scopeRef: "case-safe-001" };
    const dispatchedReceipt = { verificationDispatched: true };
    expect(
      caseSubscriptionReturnTo(
        new URL(
          "https://public.example/subscribe?returnTo=%2Fcases%2Fcase-safe-001",
        ),
        casePayload,
        dispatchedReceipt,
      ),
    ).toBe("/cases/case-safe-001");
    for (const returnTo of [
      "https://outside.example/cases/case-a",
      "//outside.example/cases/case-a",
      "/internal/cases/case-a",
      "/cases/case-a?debug=true",
      "/cases/../internal",
    ]) {
      const url = new URL("https://public.example/subscribe");
      url.searchParams.set("returnTo", returnTo);
      expect(
        caseSubscriptionReturnTo(url, casePayload, dispatchedReceipt),
      ).toBeUndefined();
    }
    expect(
      caseSubscriptionReturnTo(
        new URL(
          "https://public.example/subscribe?returnTo=%2Fcases%2Fcase-safe-001",
        ),
        { scopeType: "CASE", scopeRef: "another-case" },
        dispatchedReceipt,
      ),
    ).toBeUndefined();
    expect(
      caseSubscriptionReturnTo(
        new URL(
          "https://public.example/subscribe?returnTo=%2Fcases%2Fcase-safe-001",
        ),
        { scopeType: "AGENCY", scopeRef: "case-safe-001" },
        dispatchedReceipt,
      ),
    ).toBeUndefined();
  });

  it("returns to the case only after an explicit verification dispatch receipt", () => {
    const url = new URL(
      "https://public.example/subscribe?returnTo=%2Fcases%2Fcase-safe-001",
    );
    const payload = { scopeType: "CASE", scopeRef: "case-safe-001" };

    for (const receipt of [
      {},
      { verificationDispatched: false },
      { verificationDispatched: "true" },
    ]) {
      expect(caseSubscriptionReturnTo(url, payload, receipt)).toBeUndefined();
    }
  });

  it("binds both canonical J-01 handler IDs to executable receipt routing", () => {
    const receipt = { verificationDispatched: true };
    const url = new URL(
      "https://public.example/subscribe?returnTo=%2Fcases%2Fcase-safe-001",
    );
    const payload = { scopeType: "CASE", scopeRef: "case-safe-001" };

    expect(
      handle__j01__create_subscription_verification_receipt_v1(receipt),
    ).toBe(true);
    expect(route__j01__return_after_subscription_v1).toBe(
      caseSubscriptionReturnTo,
    );
    expect(
      route__j01__return_after_subscription_v1(url, payload, receipt),
    ).toBe("/cases/case-safe-001");
  });
});
