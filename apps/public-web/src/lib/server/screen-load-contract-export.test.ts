import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { screen as contractsScreen } from "../../routes/contracts/screen";
import { loadScreen } from "./screen-load";
import { requestEvent } from "./screen-load-test-fixtures";

const invokePublicOperation = vi.hoisted(() => vi.fn());
const privateEnv = vi.hoisted(() => ({
  BOT_CHALLENGE_SITE_KEY: "synthetic-test",
  PUBLIC_API_INTERNAL_URL: "http://public-api.test",
}));

vi.mock("@gurine/api-client-public", () => ({ invokePublicOperation }));
vi.mock("$env/dynamic/private", () => ({ env: privateEnv }));

const notice = "이상 징후 기록이며 위법·부패의 확정이 아님";
const interpretationNotice =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";
const agencyId = "00000000-0000-4000-8000-000000000001";
const otherAgencyId = "00000000-0000-4000-8000-000000000002";

function contractContent(rowNotice: string | null | undefined) {
  return `${[
    { notice },
    {
      id: "contract-1",
      contractNumber: "가상-2026-001",
      title: "가상 계약",
      agencyName: "가상 기관",
      supplierName: "가상 업체",
      status: "AWARDED",
      signedAt: "2026-07-01",
      amount: "1000",
      currency: "KRW",
      interpretationNotice: rowNotice,
    },
  ]
    .map((row) => JSON.stringify(row))
    .join("\n")}\n`;
}

function contractEnvelope(
  content: string,
  appliedFilters: Readonly<Record<string, unknown>>,
) {
  const bytes = Buffer.from(content, "utf8");
  return {
    id: "public-contracts-download",
    status: "READY",
    version: 1,
    notice,
    filename: "public-contracts.jsonl",
    mediaType: "application/x-ndjson; charset=utf-8",
    byteLength: bytes.byteLength,
    contentSha256: createHash("sha256").update(bytes).digest("hex"),
    contentBase64: bytes.toString("base64"),
    format: "JSONL",
    rowCount: 1,
    nonConclusionNotices: [],
    interpretationNotice,
    appliedFilters,
    generatedAt: "2026-07-30T00:00:00Z",
  };
}

function installContractResponses(download: unknown) {
  invokePublicOperation.mockImplementation(
    async ({ operationId }: { operationId: string }) =>
      operationId === "downloadContracts"
        ? {
            data: download,
            error: undefined,
            response: new Response(null, { status: 200 }),
          }
        : {
            data: {
              items: [],
              appliedFilters: { agencyId },
              asOf: "2026-07-30T00:00:00Z",
              seo: {
                title: "계약 대장 · 구린네",
                description: interpretationNotice,
                openGraphDescription: interpretationNotice,
                canonicalUrl: "/contracts",
                robots: "index,follow",
              },
            },
            error: undefined,
            response: new Response(null, { status: 200 }),
          },
  );
}

beforeEach(() => {
  invokePublicOperation.mockReset();
});

describe("contract download browser boundary", () => {
  it("binds current filters and exposes only a verified JSON receipt", async () => {
    const content = contractContent(interpretationNotice);
    installContractResponses(contractEnvelope(content, { agencyId }));

    const { runtime } = await loadScreen(
      requestEvent(`/contracts?agencyId=${agencyId}`),
      contractsScreen,
    );

    expect(invokePublicOperation).toHaveBeenCalledWith(
      expect.objectContaining({
        operationId: "downloadContracts",
        query: { agencyId, format: "JSONL" },
      }),
    );
    expect(runtime.downloads?.download).toEqual({
      binary: Buffer.from(
        `${JSON.stringify({
          id: "public-contracts-download",
          status: "READY",
          version: 1,
          format: "JSONL",
        })}\n`,
        "utf8",
      ).toString("base64"),
      mime: "application/json",
      extension: "json",
    });
    expect(runtime.errors).toEqual([]);
    expect(JSON.stringify(runtime)).not.toContain("contentSha256");
  });

  it.each([
    ["missing row notice", undefined, { agencyId }],
    ["null row notice", null, { agencyId }],
    ["missing filter echo", interpretationNotice, {}],
    [
      "mismatched filter echo",
      interpretationNotice,
      { agencyId: otherAgencyId },
    ],
    [
      "extra filter echo",
      interpretationNotice,
      { agencyId, signedFrom: "2026-01-01" },
    ],
  ])("omits a download with %s", async (_name, rowNotice, appliedFilters) => {
    const content = contractContent(rowNotice);
    installContractResponses(contractEnvelope(content, appliedFilters));

    const { runtime } = await loadScreen(
      requestEvent(`/contracts?agencyId=${agencyId}`),
      contractsScreen,
    );

    expect(runtime.downloads).toBeUndefined();
  });
});
