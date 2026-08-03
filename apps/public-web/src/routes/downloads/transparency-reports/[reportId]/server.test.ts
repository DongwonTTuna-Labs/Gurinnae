import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const generated = vi.hoisted(() => ({
  client: { kind: "generated-client" },
  createClient: vi.fn(),
  downloadTransparencyReport: vi.fn(),
}));
const privateEnv = vi.hoisted(() => ({
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({
  createClient: generated.createClient,
  downloadTransparencyReport: generated.downloadTransparencyReport,
}));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

import { GET } from "./+server";

const reportId = "11111111-1111-4111-8111-111111111111";
const sourceRevisionDigest = "a".repeat(64);
const projectionDigest = "b".repeat(64);
const publicContentDigest = "c".repeat(64);
const csvHeader = [
  "ordinal",
  "publicDisplay",
  "counterpartyCategory",
  "fundingSourceKind",
  "amountBandLower",
  "amountBandUpper",
  "reportingCurrency",
  "concentrationBand",
  "publicCaveat",
  "purpose",
  "conflictDisclosure",
  "mitigationSummary",
  "governmentRelated",
  "politicalPartyRelated",
  "procurementSupplierRelated",
  "investigatedSubjectRelated",
  "relatedParty",
  "publicCaseRefs",
  "publicSourceLinks",
  "entryDigest",
].join(",");

function csvEnvelope(extra: Readonly<Record<string, unknown>> = {}) {
  const metadata = [
    "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
    "reportId",
    reportId,
    "revision",
    "3",
    "sourceRevisionDigest",
    sourceRevisionDigest,
    "projectionDigest",
    projectionDigest,
    "publicContentDigest",
    publicContentDigest,
  ].join(",");
  const bytes = Buffer.from(`${metadata}\r\n${csvHeader}\r\n`, "utf8");
  return {
    reportId,
    status: "READY",
    reportKind: "FUNDING_DISCLOSURE",
    revision: 3,
    notice: "이상 징후 기록이며 위법·부패의 확정이 아님",
    filename: `gurine-funding-transparency-${reportId}.csv`,
    mediaType: "text/csv",
    byteLength: bytes.byteLength,
    contentSha256: createHash("sha256").update(bytes).digest("hex"),
    contentBase64: bytes.toString("base64"),
    format: "CSV",
    rowCount: 0,
    sourceRevisionDigest,
    projectionDigest,
    publicContentDigest,
    generatedAt: "2026-08-02T10:00:00Z",
    ...extra,
  };
}

async function invoke(
  href: string,
  pathReportId: string = reportId,
): Promise<Response> {
  return await GET({
    fetch: globalThis.fetch,
    params: { reportId: pathReportId },
    url: new URL(href, "https://public.example"),
  } as Parameters<typeof GET>[0]);
}

beforeEach(() => {
  generated.createClient.mockReset();
  generated.createClient.mockReturnValue(generated.client);
  generated.downloadTransparencyReport.mockReset();
});

describe("transparency report download route", () => {
  it("calls the named generated operation and returns only verified bytes", async () => {
    const envelope = csvEnvelope();
    generated.downloadTransparencyReport.mockResolvedValue({
      data: envelope,
      response: new Response(null, { status: 200 }),
    });

    const response = await invoke(
      `/downloads/transparency-reports/${reportId}?format=CSV`,
    );

    expect(generated.createClient).toHaveBeenCalledWith({
      baseUrl: "http://public-api.test",
      fetch: globalThis.fetch,
      responseStyle: "fields",
    });
    expect(generated.downloadTransparencyReport).toHaveBeenCalledWith({
      client: generated.client,
      path: { reportId },
      query: { format: "CSV" },
    });
    const expectedBytes = Buffer.from(envelope.contentBase64, "base64");
    expect(response.status).toBe(200);
    expect(Buffer.from(await response.arrayBuffer())).toEqual(expectedBytes);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-type")).toBe("text/csv");
    expect(response.headers.get("content-length")).toBe(
      String(expectedBytes.byteLength),
    );
    expect(response.headers.get("content-disposition")).toContain(
      `filename="gurine-funding-transparency-${reportId}.csv"`,
    );
    expect(response.headers.get("x-content-sha256")).toBe(
      envelope.contentSha256,
    );
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("defaults the closed query to JSON without exposing upstream details", async () => {
    generated.downloadTransparencyReport.mockResolvedValue({
      data: undefined,
      error: { detail: "private projection or database detail" },
      response: new Response(null, { status: 404 }),
    });

    const response = await invoke(
      `/downloads/transparency-reports/${reportId}`,
    );

    expect(generated.downloadTransparencyReport).toHaveBeenCalledWith({
      client: generated.client,
      path: { reportId },
      query: { format: "JSON" },
    });
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("투명성 보고서를 내려받지 못했습니다.");
  });

  it.each([
    400, 404, 422, 429, 500,
  ])("preserves declared upstream status %i without exposing its body", async (status) => {
    generated.downloadTransparencyReport.mockResolvedValue({
      data: undefined,
      error: { detail: "private upstream detail" },
      response: new Response(null, { status }),
    });

    const response = await invoke(
      `/downloads/transparency-reports/${reportId}`,
    );
    expect(response.status).toBe(status);
    expect(await response.text()).toBe("투명성 보고서를 내려받지 못했습니다.");
  });

  it.each([
    ["uppercase id", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "?format=JSON"],
    ["unknown query", reportId, "?source=private"],
    ["duplicate format", reportId, "?format=JSON&format=CSV"],
    ["empty format", reportId, "?format="],
    ["lowercase format", reportId, "?format=json"],
  ])("rejects %s before calling the API", async (_name, id, query) => {
    const response = await invoke(
      `/downloads/transparency-reports/${id}${query}`,
      id,
    );

    expect(response.status).toBe(400);
    expect(generated.createClient).not.toHaveBeenCalled();
    expect(generated.downloadTransparencyReport).not.toHaveBeenCalled();
  });

  it("fails closed for an invalid success envelope and network failure", async () => {
    generated.downloadTransparencyReport.mockResolvedValueOnce({
      data: csvEnvelope({ projectionDigest: "0".repeat(64) }),
      response: new Response(null, { status: 200 }),
    });
    const invalid = await invoke(
      `/downloads/transparency-reports/${reportId}?format=CSV`,
    );
    expect(invalid.status).toBe(502);

    generated.downloadTransparencyReport.mockResolvedValueOnce({
      data: csvEnvelope({
        reportId: "22222222-2222-4222-8222-222222222222",
      }),
      response: new Response(null, { status: 200 }),
    });
    const mismatchedReport = await invoke(
      `/downloads/transparency-reports/${reportId}?format=CSV`,
    );
    expect(mismatchedReport.status).toBe(502);

    generated.downloadTransparencyReport.mockRejectedValueOnce(
      new Error("private upstream address"),
    );
    const unavailable = await invoke(
      `/downloads/transparency-reports/${reportId}?format=CSV`,
    );
    expect(unavailable.status).toBe(503);
    expect(await unavailable.text()).not.toContain("private upstream address");
  });
});
