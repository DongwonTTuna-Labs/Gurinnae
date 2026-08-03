import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  PUBLIC_REDISTRIBUTION_NOTICE,
  verifyTransparencyReportDownload,
} from "./transparency-report-download";

const reportId = "11111111-1111-4111-8111-111111111111";
const sourceRevisionDigest = "a".repeat(64);
const projectionDigest = "b".repeat(64);
const publicContentDigest = "c".repeat(64);
const entryDigest = "d".repeat(64);
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
const csvMetadata = [
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

function publicReport(extra: Record<string, unknown> = {}) {
  return {
    caveat: "승인된 분모가 없어 집중도를 산출하지 않습니다.",
    concentrationBand: "UNKNOWN",
    disclosureId: "22222222-2222-4222-8222-222222222222",
    effectiveAt: "2026-04-02T00:00:00Z",
    entries: [
      {
        amountBandLower: "10000.000000",
        amountBandUpper: "50000.000000",
        concentrationBand: "UNKNOWN",
        concentrationUnknownReason: "DENOMINATOR_UNKNOWN",
        conflictDisclosure: "조사 우선순위와 분리",
        counterpartyCategory: "개인 후원",
        denominatorUnknownReason: "APPROVAL_MISSING",
        entryDigest,
        fundingSourceKind: "DONATION",
        governmentRelated: false,
        groupingDisputeReason: null,
        identityDisclosureMode: "CATEGORY_ONLY",
        investigatedSubjectRelated: false,
        mitigationSummary: "독립 검토와 공개",
        ordinal: 1,
        politicalPartyRelated: false,
        procurementSupplierRelated: false,
        publicCaseRefs: [],
        publicCaveatText: "승인된 분모가 없습니다.",
        publicDisplayName: null,
        publicSourceLinks: ["https://example.test/public-funding-evidence"],
        purpose: "공익 플랫폼 운영",
        relatedParty: false,
        reportingCurrency: "KRW",
        withholdingPublicExplanation: "명명 기준 미만 범주 공개",
      },
    ],
    fiscalQuarter: 1,
    fiscalYear: 2026,
    periodEnd: "2026-04-01",
    periodStart: "2026-01-01",
    policyRequests: {
      accepted: 0,
      outcomeDigest: "e".repeat(64),
      partiallyAccepted: 0,
      pending: 0,
      rejected: 0,
      total: 0,
      withdrawn: 0,
    },
    publicContentDigest,
    publishedAt: "2026-04-02T00:00:00Z",
    purpose: "독립 승인된 테스트 공개 재원",
    reportingCurrency: "KRW",
    revision: 3,
    schemaVersion: 1,
    sourceRevisionDigest,
    sources: ["https://example.test/public-funding-evidence"],
    supersedesRevision: 2,
    ...extra,
  };
}

function jsonBytes(report = publicReport()): Uint8Array {
  return Buffer.from(
    JSON.stringify({
      notice: "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
      projectionDigest,
      report,
      reportId,
      schemaVersion: 1,
      sourceRevision: 3,
      sourceRevisionDigest,
    }),
    "utf8",
  );
}

function envelope(bytes = jsonBytes(), extra: Record<string, unknown> = {}) {
  return {
    reportId,
    status: "READY",
    reportKind: "FUNDING_DISCLOSURE",
    revision: 3,
    notice: PUBLIC_REDISTRIBUTION_NOTICE,
    filename: `gurine-funding-transparency-${reportId}.json`,
    mediaType: "application/json",
    byteLength: bytes.byteLength,
    contentSha256: createHash("sha256").update(bytes).digest("hex"),
    contentBase64: Buffer.from(bytes).toString("base64"),
    format: "JSON",
    rowCount: 1,
    sourceRevisionDigest,
    projectionDigest,
    publicContentDigest,
    generatedAt: "2026-08-02T10:00:00Z",
    ...extra,
  };
}

describe("transparency report download verification", () => {
  it("accepts exact canonical JSON bytes and digest bindings", () => {
    expect(
      verifyTransparencyReportDownload(envelope(), {
        reportId,
        format: "JSON",
      }),
    ).toMatchObject({
      filename: `gurine-funding-transparency-${reportId}.json`,
      mediaType: "application/json",
      contentSha256: createHash("sha256").update(jsonBytes()).digest("hex"),
    });
  });

  it("rejects byte, filename, revision and public-content mismatches", () => {
    expect(
      verifyTransparencyReportDownload(
        envelope(jsonBytes(), { byteLength: 1 }),
        {
          reportId,
          format: "JSON",
        },
      ),
    ).toBeNull();
    expect(
      verifyTransparencyReportDownload(
        envelope(jsonBytes(), { filename: "report.json" }),
        { reportId, format: "JSON" },
      ),
    ).toBeNull();
    expect(
      verifyTransparencyReportDownload(envelope(jsonBytes(), { revision: 4 }), {
        reportId,
        format: "JSON",
      }),
    ).toBeNull();
    expect(
      verifyTransparencyReportDownload(
        envelope(jsonBytes(), { publicContentDigest: "d".repeat(64) }),
        { reportId, format: "JSON" },
      ),
    ).toBeNull();
  });

  it("rejects noncanonical base64 and JSON bytes", () => {
    const noncanonicalJson = Buffer.from(
      ` ${Buffer.from(jsonBytes())}`,
      "utf8",
    );
    expect(
      verifyTransparencyReportDownload(envelope(noncanonicalJson), {
        reportId,
        format: "JSON",
      }),
    ).toBeNull();
    expect(
      verifyTransparencyReportDownload(
        envelope(jsonBytes(), {
          contentBase64: `${Buffer.from(jsonBytes()).toString("base64")}=`,
        }),
        { reportId, format: "JSON" },
      ),
    ).toBeNull();
  });

  it("rejects private or otherwise unknown fields inside the public report", () => {
    const bytes = jsonBytes(publicReport({ providerPaymentId: "private" }));
    expect(
      verifyTransparencyReportDownload(envelope(bytes), {
        reportId,
        format: "JSON",
      }),
    ).toBeNull();
  });

  it("accepts exact CSV structure and a legitimate zero-row report", () => {
    const bytes = Buffer.from(
      `${csvMetadata}\r\n${csvHeader}\r\n1,개인 후원,개인 후원,DONATION,10000.000000,50000.000000,KRW,UNKNOWN,승인된 분모가 없습니다.,공익 플랫폼 운영,조사 우선순위와 분리,독립 검토와 공개,false,false,false,false,false,,https://example.test/public-funding-evidence,${entryDigest}\r\n`,
      "utf8",
    );
    const csv = envelope(bytes, {
      filename: `gurine-funding-transparency-${reportId}.csv`,
      mediaType: "text/csv",
      format: "CSV",
    });
    expect(
      verifyTransparencyReportDownload(csv, { reportId, format: "CSV" }),
    ).toMatchObject({ mediaType: "text/csv" });
    expect(
      verifyTransparencyReportDownload(csv, { reportId, format: "JSON" }),
    ).toBeNull();

    const emptyBytes = Buffer.from(
      `${csvMetadata}\r\n${csvHeader}\r\n`,
      "utf8",
    );
    expect(
      verifyTransparencyReportDownload(
        envelope(emptyBytes, {
          filename: `gurine-funding-transparency-${reportId}.csv`,
          mediaType: "text/csv",
          format: "CSV",
          rowCount: 0,
        }),
        { reportId, format: "CSV" },
      ),
    ).toMatchObject({ mediaType: "text/csv" });
  });

  it("rejects malformed CSV rows and formula-capable cells", () => {
    for (const content of [
      `${csvMetadata}\r\n${csvHeader}\r\n`,
      `${csvMetadata}\r\n${csvHeader}\r\n1,=HYPERLINK("https://private.test")\r\n`,
    ]) {
      const bytes = Buffer.from(content, "utf8");
      expect(
        verifyTransparencyReportDownload(
          envelope(bytes, {
            filename: `gurine-funding-transparency-${reportId}.csv`,
            mediaType: "text/csv",
            format: "CSV",
          }),
          { reportId, format: "CSV" },
        ),
      ).toBeNull();
    }
  });

  it("rejects CSV metadata that is not bound to the envelope digests", () => {
    const bytes = Buffer.from(
      `${csvMetadata.replace(projectionDigest, "f".repeat(64))}\r\n${csvHeader}\r\n1,개인 후원,개인 후원,DONATION,10000.000000,50000.000000,KRW,UNKNOWN,승인된 분모가 없습니다.,공익 플랫폼 운영,조사 우선순위와 분리,독립 검토와 공개,false,false,false,false,false,,https://example.test/public-funding-evidence,${entryDigest}\r\n`,
      "utf8",
    );
    expect(
      verifyTransparencyReportDownload(
        envelope(bytes, {
          filename: `gurine-funding-transparency-${reportId}.csv`,
          mediaType: "text/csv",
          format: "CSV",
        }),
        { reportId, format: "CSV" },
      ),
    ).toBeNull();
  });
});
