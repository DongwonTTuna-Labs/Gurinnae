import { describe, expect, it } from "vitest";
import {
  PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE,
  PUBLIC_FUNDING_EXPENSE_PRESENTATION_NOTICE,
  publicFundingPresentation,
} from "./public-funding-presentation";

const reportId = "11111111-1111-4111-8111-111111111111";
const updatedAt = "2026-08-02T10:00:00Z";
const notice = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";

function content(status: "AVAILABLE" | "UNKNOWN" = "AVAILABLE") {
  const available = status === "AVAILABLE";
  return {
    id: {
      id: "funding",
      status: available ? "PUBLISHED" : "UNKNOWN",
      version: available ? 3 : 1,
    },
    version: available ? 3 : 1,
    status,
    updatedAt,
    title: "재원 공개",
    summary: available
      ? "승인된 공개 개정 3"
      : "승인된 공개 재원 개정본을 기다리고 있습니다.",
    data: {
      version: "1.0",
      title: "재원 공개",
      updatedAt,
      sections: [
        section("principles", "독립성 원칙", notice, [
          {
            rel: "policy",
            href: "/about/governance",
            label: "거버넌스와 독립성",
          },
        ]),
        section(
          "income",
          "재원",
          available
            ? "공개 후원 · 집중도 확인 불가"
            : "승인 개정본이 없어 재원 상태를 확인할 수 없습니다.",
        ),
        section("expenses", "비용", PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE),
        section(
          "donors",
          "공개 기준",
          available
            ? "승인된 공개 항목"
            : "승인 개정본이 없어 후원 공개 상태를 확인할 수 없습니다.",
        ),
        section(
          "conflicts",
          "이해상충",
          available
            ? `집중도 확인 불가 · ${notice}`
            : "공개 개정본이 없어 이해상충 상태를 확인할 수 없습니다.",
        ),
        section(
          "reports",
          "보고서",
          available ? "2026년 2분기 · 개정 3" : "승인 보고서가 없습니다.",
          available
            ? [
                {
                  rel: "download",
                  href: `/v1/transparency-reports/${reportId}/download`,
                  label: "투명성 보고서 다운로드",
                },
              ]
            : [],
        ),
      ],
      sourceLinks: [],
    },
    links: [
      { rel: "self", href: "/v1/content/funding" },
      { rel: "reports", href: "/v1/transparency-reports" },
    ],
  };
}

function section(
  id: string,
  heading: string,
  body: string,
  links: readonly Record<string, unknown>[] = [],
) {
  return { id, heading, body, links, updatedAt };
}

function reports(items: readonly Record<string, unknown>[] = [report()]) {
  return { items, appliedFilters: {}, asOf: updatedAt };
}

function report(extra: Record<string, unknown> = {}) {
  return {
    id: reportId,
    periodStart: "2026-04-01",
    periodEnd: "2026-07-01",
    title: "2026년 2분기 재원 보고서",
    summary: "승인 공개 개정 3",
    publishedAt: updatedAt,
    href: `/v1/transparency-reports/${reportId}/download`,
    ...extra,
  };
}

describe("public funding presentation", () => {
  it("projects approved disclosure sections and owned download routes", () => {
    const result = publicFundingPresentation("PUB-023", {
      getFundingContent: content(),
      listTransparencyReports: reports(),
    });

    expect(result).toMatchObject({
      status: "AVAILABLE",
      summary: "승인된 공개 개정 3",
      reports: [
        {
          id: reportId,
          jsonDownloadHref: `/downloads/transparency-reports/${reportId}?format=JSON`,
          csvDownloadHref: `/downloads/transparency-reports/${reportId}?format=CSV`,
        },
      ],
    });
    expect(result?.sections.map((item) => [item.id, item.status])).toEqual([
      ["principles", "AVAILABLE"],
      ["income", "AVAILABLE"],
      ["expenses", "UNAVAILABLE"],
      ["donors", "AVAILABLE"],
      ["conflicts", "AVAILABLE"],
      ["reports", "AVAILABLE"],
    ]);
    expect(
      result?.sections.find((item) => item.id === "reports")?.links,
    ).toEqual([]);
  });

  it("keeps actual UNKNOWN reasons and unavailable expense authority", () => {
    const result = publicFundingPresentation("PUB-023", {
      getFundingContent: content("UNKNOWN"),
      listTransparencyReports: reports([]),
    });

    expect(result?.status).toBe("UNKNOWN");
    expect(result?.reports).toEqual([]);
    expect(result?.sections.find((item) => item.id === "income")).toMatchObject(
      {
        status: "UNKNOWN",
        body: "승인 개정본이 없어 재원 상태를 확인할 수 없습니다.",
      },
    );
    expect(
      result?.sections.find((item) => item.id === "expenses")?.status,
    ).toBe("UNAVAILABLE");
    expect(result?.sections.find((item) => item.id === "expenses")?.body).toBe(
      PUBLIC_FUNDING_EXPENSE_PRESENTATION_NOTICE,
    );
  });

  it("keeps verified content and marks only reports unavailable when the list fails", () => {
    const result = publicFundingPresentation("PUB-023", {
      getFundingContent: content(),
    });

    expect(result?.status).toBe("AVAILABLE");
    expect(result?.reports).toEqual([]);
    expect(result?.sections).toContainEqual(
      expect.objectContaining({ id: "principles", status: "AVAILABLE" }),
    );
    expect(result?.sections).toContainEqual(
      expect.objectContaining({ id: "reports", status: "UNAVAILABLE" }),
    );
  });

  it("keeps runtime status tokens out of user-facing funding copy", () => {
    const result = publicFundingPresentation("PUB-023", {
      getFundingContent: content(),
      listTransparencyReports: reports(),
    });
    const copy = [
      result?.summary,
      ...(result?.sections ?? []).flatMap((item) => [item.heading, item.body]),
      ...(result?.reports ?? []).flatMap((item) => [item.title, item.summary]),
    ].join("\n");

    expect(copy).not.toMatch(
      /UNKNOWN|UNAVAILABLE|disclosure|projection|revision|transparency report/iu,
    );
    expect(copy).not.toContain("권위");
  });

  it("fails closed for stale hrefs, private fields and missing reports", () => {
    expect(() =>
      publicFundingPresentation("PUB-023", {
        getFundingContent: content(),
        listTransparencyReports: reports([
          report({ href: `https://private.test/${reportId}` }),
        ]),
      }),
    ).toThrow("funding report binding mismatch");

    const withPrivateField = content() as Record<string, unknown>;
    withPrivateField.rawDonorIdentity = "forbidden";
    expect(() =>
      publicFundingPresentation("PUB-023", {
        getFundingContent: withPrivateField,
        listTransparencyReports: reports(),
      }),
    ).toThrow("funding content contract mismatch");

    expect(() =>
      publicFundingPresentation("PUB-023", {
        getFundingContent: content(),
        listTransparencyReports: {
          ...reports(),
          rawApprovalNote: "forbidden",
        },
      }),
    ).toThrow("funding report list contract mismatch");

    expect(() =>
      publicFundingPresentation("PUB-023", {
        getFundingContent: content(),
        listTransparencyReports: reports([]),
      }),
    ).toThrow("funding report authority mismatch");
  });
});
