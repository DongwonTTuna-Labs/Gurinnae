import { beforeEach, describe, expect, it, vi } from "vitest";
import { screen } from "../../routes/about/funding/screen";
import { PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE } from "./public-funding-presentation";
import {
  loadScreen,
  PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE,
  PUBLIC_FUNDING_TEST_FIXTURE_QUERY,
} from "./screen-load";
import { requestEvent } from "./screen-load-test-fixtures";

const invokePublicOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  BOT_CHALLENGE_SITE_KEY: "synthetic-test",
  GURINE_ENV: "test",
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({ invokePublicOperation }));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

const firstReportId = "11111111-1111-4111-8111-111111111111";
const secondReportId = "22222222-2222-4222-8222-222222222222";
const updatedAt = "2026-08-02T10:00:00Z";

beforeEach(() => {
  privateEnv.GURINE_ENV = "test";
  invokePublicOperation.mockReset();
  invokePublicOperation.mockImplementation(
    ({ operationId }: { operationId: string }) =>
      Promise.resolve(
        operationId === "getFundingContent"
          ? success(fundingContent())
          : success(transparencyReports()),
      ),
  );
});

describe("PUB-023 screen load", () => {
  it("binds the primary action to the first approved report", async () => {
    const { runtime } = await loadScreen(
      requestEvent("/about/funding"),
      screen,
    );

    expect(runtime.state).toBe("success");
    expect(runtime.destinations?.["download-report"]).toBe(
      `/downloads/transparency-reports/${firstReportId}?format=JSON`,
    );
    expect(runtime.fundingTransparency?.reports.map(({ id }) => id)).toEqual([
      firstReportId,
      secondReportId,
    ]);
  });

  it("keeps approved content visible as partial when the report list is unavailable", async () => {
    invokePublicOperation.mockImplementation(
      ({
        operationId,
        query,
      }: {
        operationId: string;
        query?: Record<string, unknown>;
      }) => {
        if (operationId === "getFundingContent") {
          return Promise.resolve(success(fundingContent()));
        }
        expect(query).toEqual({
          [PUBLIC_FUNDING_TEST_FIXTURE_QUERY]:
            PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE,
        });
        return Promise.resolve({
          data: undefined,
          error: { title: "INTERNAL_ERROR" },
          response: new Response(null, { status: 500 }),
        });
      },
    );

    const path = `/about/funding?${PUBLIC_FUNDING_TEST_FIXTURE_QUERY}=${PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE}`;
    const { runtime } = await loadScreen(requestEvent(path), screen);

    expect(runtime.state).toBe("partial");
    expect(runtime.errors).toEqual([]);
    expect(runtime.fundingTransparency?.sections).toContainEqual(
      expect.objectContaining({ id: "reports", status: "UNAVAILABLE" }),
    );
    expect(runtime.fundingTransparency?.reports).toEqual([]);
    expect(runtime.destinations).not.toHaveProperty("download-report");
    expect(runtime.fundingTransparency?.sections).toContainEqual(
      expect.objectContaining({ id: "principles", status: "AVAILABLE" }),
    );
  });

  it("never forwards the TEST_FIXTURE selector outside the test environment", async () => {
    privateEnv.GURINE_ENV = "production";
    const path = `/about/funding?${PUBLIC_FUNDING_TEST_FIXTURE_QUERY}=${PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE}`;

    await loadScreen(requestEvent(path), screen);

    expect(invokePublicOperation).toHaveBeenCalledWith(
      expect.objectContaining({
        operationId: "listTransparencyReports",
        query: {},
      }),
    );
  });
});

function success(data: unknown) {
  return {
    data,
    error: undefined,
    response: new Response(null, { status: 200 }),
  };
}

function fundingContent() {
  const section = (
    id:
      | "principles"
      | "income"
      | "expenses"
      | "donors"
      | "conflicts"
      | "reports",
    heading: string,
    body: string,
  ) => ({ id, heading, body, links: [], updatedAt });
  return {
    id: { id: "funding", status: "PUBLISHED", version: 3 },
    version: 3,
    status: "AVAILABLE",
    updatedAt,
    title: "재원 공개",
    summary: "승인된 공개 재원 개정 3",
    data: {
      version: "1.0",
      title: "재원 공개",
      updatedAt,
      sections: [
        section(
          "principles",
          "독립성 원칙",
          "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
        ),
        section("income", "재원", "승인된 공개 후원 범주"),
        section("expenses", "비용", PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE),
        section("donors", "공개 기준", "승인된 공개 항목"),
        section("conflicts", "이해상충", "독립 검토와 공개"),
        section("reports", "보고서", "승인된 공개 개정 2건"),
      ],
      sourceLinks: [],
    },
    links: [
      { rel: "self", href: "/v1/content/funding" },
      { rel: "reports", href: "/v1/transparency-reports" },
    ],
  };
}

function transparencyReports() {
  return {
    items: [
      report(firstReportId, "2026-01-01", "2026-04-01", "1분기"),
      report(secondReportId, "2026-04-01", "2026-07-01", "2분기"),
    ],
    appliedFilters: {},
    asOf: updatedAt,
  };
}

function report(
  id: string,
  periodStart: string,
  periodEnd: string,
  period: string,
) {
  return {
    id,
    periodStart,
    periodEnd,
    title: `2026년 ${period} 재원 보고서`,
    summary: "승인 공개 개정",
    publishedAt: updatedAt,
    href: `/v1/transparency-reports/${id}/download`,
  };
}
