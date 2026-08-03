import { describe, expect, it } from "vitest";
import { publicFundingPresentation } from "../../../apps/public-web/src/lib/server/public-funding-presentation";
import { verifyTransparencyReportDownload } from "../../../apps/public-web/src/lib/server/transparency-report-download";
import {
  FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE,
  FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE_QUERY,
  publicFundingRead,
} from "./mock-api-funding";

const origin = "http://mock.test";
const reportId = "55555555-5555-4555-8555-555555555555";

async function fundingJson(path: string): Promise<unknown> {
  const response = publicFundingRead(new URL(path, origin));
  if (!response) throw new Error(`funding fixture did not handle ${path}`);
  return response.json() as Promise<unknown>;
}

describe("R6e public funding mock", () => {
  it("projects a current strict PUB-023 view model with live report links", async () => {
    const getFundingContent = await fundingJson("/v1/content/funding");
    const listTransparencyReports = await fundingJson(
      "/v1/transparency-reports",
    );

    const viewModel = publicFundingPresentation("PUB-023", {
      getFundingContent,
      listTransparencyReports,
    });

    expect(viewModel).toMatchObject({
      status: "AVAILABLE",
      reports: [
        {
          id: reportId,
          jsonDownloadHref: `/downloads/transparency-reports/${reportId}?format=JSON`,
          csvDownloadHref: `/downloads/transparency-reports/${reportId}?format=CSV`,
        },
      ],
    });
    expect(JSON.stringify(viewModel)).toContain(
      "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
    );
    const publicCopy = [
      viewModel?.summary,
      ...(viewModel?.sections ?? []).flatMap((item) => [
        item.heading,
        item.body,
      ]),
      ...(viewModel?.reports ?? []).flatMap((item) => [
        item.title,
        item.summary,
      ]),
    ].join("\n");
    expect(publicCopy).not.toMatch(
      /UNKNOWN|UNAVAILABLE|disclosure|projection|revision|transparency report/iu,
    );
  });

  it.each([
    "JSON",
    "CSV",
  ] as const)("emits deterministic verified %s bytes without private payment fields", async (format) => {
    const path = `/v1/transparency-reports/${reportId}/download?format=${format}`;
    const first = await fundingJson(path);
    const second = await fundingJson(path);
    expect(first).toEqual(second);

    const verified = verifyTransparencyReportDownload(first, {
      reportId,
      format,
    });
    expect(verified).not.toBeNull();
    const text = new TextDecoder().decode(verified?.bytes);
    expect(text).not.toMatch(
      /billingKey|providerPaymentId|paymentAuthorizationToken|donorId/u,
    );
  });

  it("rejects unknown report IDs with the closed additive problem", async () => {
    const response = publicFundingRead(
      new URL(
        "/v1/transparency-reports/77777777-7777-4777-8777-777777777777/download",
        origin,
      ),
    );
    expect(response?.status).toBe(404);
    await expect(response?.json()).resolves.toEqual({
      code: "RESOURCE_NOT_FOUND",
      title: "RESOURCE_NOT_FOUND",
      status: 404,
      requestId: expect.any(String),
    });
  });

  it("keeps content available while the explicit TEST_FIXTURE report list fails closed", async () => {
    const content = publicFundingRead(new URL("/v1/content/funding", origin));
    const unavailable = publicFundingRead(
      new URL(
        `/v1/transparency-reports?${FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE_QUERY}=${FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE}`,
        origin,
      ),
    );
    const ordinary = publicFundingRead(
      new URL("/v1/transparency-reports", origin),
    );

    expect(content?.status).toBe(200);
    expect(unavailable?.status).toBe(500);
    await expect(unavailable?.json()).resolves.toMatchObject({
      code: "INTERNAL_ERROR",
      status: 500,
      type: "about:blank",
    });
    expect(ordinary?.status).toBe(200);
  });

  it("rejects non-closed format queries", () => {
    for (const query of [
      "format=PDF",
      "format=JSON&format=CSV",
      "format=CSV&unexpected=true",
    ]) {
      expect(
        publicFundingRead(
          new URL(
            `/v1/transparency-reports/${reportId}/download?${query}`,
            origin,
          ),
        )?.status,
      ).toBe(400);
    }
  });
});
