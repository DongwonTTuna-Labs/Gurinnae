import { describe, expect, it } from "vitest";
import { subscriptionPreset, subscriptionQuery } from "./subscription-preset";

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
});
