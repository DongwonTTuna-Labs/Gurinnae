import { describe, expect, it } from "vitest";
import { screen as caseDetailScreen } from "../../routes/cases/[caseSlug]/screen";
import { screen as caseLedgerScreen } from "../../routes/cases/screen";
import { screen as searchScreen } from "../../routes/search/screen";
import { publicScreenDestinations } from "./screen-destinations";

describe("public screen destinations", () => {
  it("carries only the canonical case source route into the optional subscription branch", () => {
    const destination = publicScreenDestinations(
      caseDetailScreen,
      "/cases/case-safe-001",
      {},
    )["subscribe-case"];

    expect(destination).toBeDefined();
    const url = new URL(destination ?? "", "https://public.example");
    expect(url.pathname).toBe("/subscribe");
    expect(url.searchParams.get("scope")).toBe("CASE");
    expect(url.searchParams.get("ref")).toBe("case-safe-001");
    expect(url.searchParams.get("returnTo")).toBe("/cases/case-safe-001");
  });

  it("keeps both region filters in a closed query subscription snapshot", () => {
    const destination = publicScreenDestinations(
      caseLedgerScreen,
      "/cases",
      {},
      new URLSearchParams({
        sidoCode: "11",
        sigunguCode: "11680",
        internalNote: "must-not-survive",
      }),
    )["subscribe-filter"];

    expect(destination).toBeDefined();
    const url = new URL(destination ?? "", "https://public.example");
    expect(JSON.parse(url.searchParams.get("query") ?? "null")).toEqual({
      route: "/cases",
      filters: [
        { name: "sidoCode", values: ["11"] },
        { name: "sigunguCode", values: ["11680"] },
      ],
      sort: "updated_desc",
    });
  });

  it("binds both export formats to the current case filters without pagination", () => {
    const destinations = publicScreenDestinations(
      caseLedgerScreen,
      "/cases",
      {},
      new URLSearchParams({
        publicationState: "PUBLISHED_ANOMALY",
        sidoCode: "11",
        cursor: "old-page",
        limit: "100",
      }),
    );

    expect(destinations["download-csv"]).toBe(
      "/downloads/cases?publicationState=PUBLISHED_ANOMALY&sidoCode=11&sort=updated_desc&format=CSV",
    );
    expect(destinations["download-jsonl"]).toBe(
      "/downloads/cases?publicationState=PUBLISHED_ANOMALY&sidoCode=11&sort=updated_desc&format=JSONL",
    );
  });

  it("does not expose search downloads before a valid search term exists", () => {
    expect(
      publicScreenDestinations(
        searchScreen,
        "/search",
        {},
        new URLSearchParams(),
      ),
    ).not.toHaveProperty("download-csv");
  });
});
