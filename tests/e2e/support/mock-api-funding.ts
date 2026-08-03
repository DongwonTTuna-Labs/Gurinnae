import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE } from "../../../apps/public-web/src/lib/server/public-funding-presentation";
import { addendumProblem, problem } from "./mock-api-state";

const DONATION_NOTICE = "후원은 접근권이 아니며 조사 대상 면제가 아닙니다";
const REDISTRIBUTION_NOTICE = "이상 징후 기록이며 위법·부패의 확정이 아님";
const REPORT_ID = "55555555-5555-4555-8555-555555555555";
export const FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE_QUERY = "__testFixture";
export const FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE = "FUNDING_LIST_UNAVAILABLE";
const DISCLOSURE_ID = "66666666-6666-4666-8666-666666666666";
const UPDATED_AT = "2026-08-02T12:00:00Z";
const SOURCE_LINK = "https://example.test/public-funding-evidence";
const sha256 = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const sourceRevisionDigest = sha256(
  "TEST_FIXTURE:r6e-funding-source-revision:1",
);
const entryDigest = sha256("TEST_FIXTURE:r6e-funding-entry:1");
const policyOutcomeDigest = sha256(
  "TEST_FIXTURE:r6e-funding-policy-outcome:zero-requests",
);
const publicEntry = Object.freeze({
  ordinal: 1,
  identityDisclosureMode: "CATEGORY_ONLY",
  publicDisplayName: null,
  withholdingPublicExplanation: "테스트 fixture 공개 범주",
  counterpartyCategory: "개인 후원",
  fundingSourceKind: "DONATION",
  amountBandLower: "10000.000000",
  amountBandUpper: "50000.000000",
  reportingCurrency: "KRW",
  concentrationBand: "UNKNOWN",
  denominatorUnknownReason: "APPROVAL_MISSING",
  groupingDisputeReason: null,
  concentrationUnknownReason: "DENOMINATOR_UNKNOWN",
  publicCaveatText: "승인된 분모가 없어 집중도를 산출하지 않습니다.",
  purpose: "공개 화면 검증용 후원 fixture",
  conflictDisclosure: "조사 우선순위와 분리",
  mitigationSummary: "독립 검토와 공개",
  governmentRelated: false,
  politicalPartyRelated: false,
  procurementSupplierRelated: false,
  investigatedSubjectRelated: false,
  relatedParty: false,
  publicCaseRefs: [],
  publicSourceLinks: [SOURCE_LINK],
  entryDigest,
});

const reportWithoutContentDigest = {
  schemaVersion: 1,
  disclosureId: DISCLOSURE_ID,
  revision: 1,
  fiscalYear: 2026,
  fiscalQuarter: 1,
  periodStart: "2026-01-01",
  periodEnd: "2026-04-01",
  reportingCurrency: "KRW",
  concentrationBand: "UNKNOWN",
  caveat: "승인된 분모가 없어 집중도를 산출하지 않습니다.",
  purpose: "독립 승인된 테스트 공개 재원",
  policyRequests: {
    total: 0,
    accepted: 0,
    partiallyAccepted: 0,
    rejected: 0,
    withdrawn: 0,
    pending: 0,
    outcomeDigest: policyOutcomeDigest,
  },
  sources: [SOURCE_LINK],
  entries: [publicEntry],
  effectiveAt: UPDATED_AT,
  publishedAt: UPDATED_AT,
  supersedesRevision: null,
  sourceRevisionDigest,
};
const publicContentDigest = sha256(canonicalJson(reportWithoutContentDigest));
const publicReport = Object.freeze({
  ...reportWithoutContentDigest,
  publicContentDigest,
});
const projectionDigest = sha256(
  canonicalJson({
    fixtureAuthority: "TEST_FIXTURE",
    reportId: REPORT_ID,
    report: publicReport,
  }),
);

const CSV_HEADERS = [
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
] as const;

export function publicFundingRead(url: URL): Response | undefined {
  if (url.pathname === "/v1/content/funding") {
    return Response.json(fundingContent());
  }
  if (url.pathname === "/v1/transparency-reports") {
    if (
      url.searchParams.getAll(FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE_QUERY)
        .length === 1 &&
      url.searchParams.get(FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE_QUERY) ===
        FUNDING_LIST_UNAVAILABLE_TEST_FIXTURE
    ) {
      return problem(500, "INTERNAL_ERROR");
    }
    return Response.json(fundingReportList());
  }
  const match = url.pathname.match(
    /^\/v1\/transparency-reports\/([0-9a-f-]+)\/download$/u,
  );
  if (!match) return undefined;
  if (match[1] !== REPORT_ID) return addendumProblem(404, "RESOURCE_NOT_FOUND");
  const format = downloadFormat(url.searchParams);
  if (!format) return addendumProblem(400, "INVALID_PARAMETER");
  return Response.json(fundingReportDownload(format));
}

function fundingContent() {
  const section = (
    id: string,
    heading: string,
    body: string,
    links: readonly Record<string, string>[] = [],
  ) => ({ id, heading, body, links, updatedAt: UPDATED_AT });
  return {
    id: { id: "funding", status: "PUBLISHED", version: 1 },
    version: 1,
    status: "AVAILABLE",
    updatedAt: UPDATED_AT,
    title: "재원 공개",
    summary: "독립 승인된 공개 재원 개정본과 미확정 범위를 함께 표시합니다.",
    data: {
      version: "1.0",
      title: "재원 공개",
      updatedAt: UPDATED_AT,
      sections: [
        section("principles", "독립성 원칙", DONATION_NOTICE),
        section(
          "income",
          "재원",
          "승인 공개 후원 범주가 있으며 집중도 산정 분모는 확인되지 않았습니다.",
          [{ rel: "source", href: SOURCE_LINK, label: "승인 공개 근거 1" }],
        ),
        section("expenses", "비용", PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE),
        section("donors", "공개 기준", "개인 후원 · 승인 공개 금액대"),
        section(
          "conflicts",
          "이해상충",
          `집중도 확인 불가 · ${DONATION_NOTICE}`,
          [{ rel: "policy", href: "/about/governance", label: "독립성 정책" }],
        ),
        section("reports", "보고서", "2026년 1분기 · 개정 1", [
          {
            rel: "download",
            href: `/v1/transparency-reports/${REPORT_ID}/download`,
            label: "투명성 보고서 다운로드",
          },
        ]),
      ],
      sourceLinks: [
        { rel: "source", href: SOURCE_LINK, label: "승인 공개 근거 1" },
      ],
    },
    links: [
      { rel: "self", href: "/v1/content/funding" },
      { rel: "reports", href: "/v1/transparency-reports" },
    ],
  };
}

function fundingReportList() {
  return {
    items: [
      {
        id: REPORT_ID,
        periodStart: "2026-01-01",
        periodEnd: "2026-04-01",
        title: "2026년 1분기 재원 공개",
        summary: "독립 승인된 공개 재원 개정 1",
        publishedAt: UPDATED_AT,
        href: `/v1/transparency-reports/${REPORT_ID}/download`,
      },
    ],
    appliedFilters: {},
    asOf: UPDATED_AT,
  };
}

function fundingReportDownload(format: "JSON" | "CSV") {
  const bytes =
    format === "JSON"
      ? Buffer.from(
          canonicalJson({
            schemaVersion: 1,
            notice: DONATION_NOTICE,
            reportId: REPORT_ID,
            sourceRevision: 1,
            sourceRevisionDigest,
            projectionDigest,
            report: publicReport,
          }),
          "utf8",
        )
      : fundingCsv();
  const extension = format === "JSON" ? "json" : "csv";
  return {
    reportId: REPORT_ID,
    status: "READY",
    reportKind: "FUNDING_DISCLOSURE",
    revision: 1,
    notice: REDISTRIBUTION_NOTICE,
    filename: `gurine-funding-transparency-${REPORT_ID}.${extension}`,
    mediaType: format === "JSON" ? "application/json" : "text/csv",
    byteLength: bytes.byteLength,
    contentSha256: sha256(bytes),
    contentBase64: bytes.toString("base64"),
    format,
    rowCount: 1,
    sourceRevisionDigest,
    projectionDigest,
    publicContentDigest,
    generatedAt: UPDATED_AT,
  };
}

function fundingCsv(): Buffer {
  const row = [
    publicEntry.ordinal,
    publicEntry.counterpartyCategory,
    publicEntry.counterpartyCategory,
    publicEntry.fundingSourceKind,
    publicEntry.amountBandLower,
    publicEntry.amountBandUpper,
    publicEntry.reportingCurrency,
    publicEntry.concentrationBand,
    publicEntry.publicCaveatText,
    publicEntry.purpose,
    publicEntry.conflictDisclosure,
    publicEntry.mitigationSummary,
    publicEntry.governmentRelated,
    publicEntry.politicalPartyRelated,
    publicEntry.procurementSupplierRelated,
    publicEntry.investigatedSubjectRelated,
    publicEntry.relatedParty,
    publicEntry.publicCaseRefs.join("|"),
    publicEntry.publicSourceLinks.join("|"),
    publicEntry.entryDigest,
  ];
  const metadata = [
    DONATION_NOTICE,
    "reportId",
    REPORT_ID,
    "revision",
    publicReport.revision,
    "sourceRevisionDigest",
    sourceRevisionDigest,
    "projectionDigest",
    projectionDigest,
    "publicContentDigest",
    publicContentDigest,
  ];
  const content = [metadata, CSV_HEADERS, row]
    .map((record) => record.map((value) => csvCell(String(value))).join(","))
    .join("\r\n");
  return Buffer.from(`${content}\r\n`, "utf8");
}

function csvCell(value: string): string {
  const formulaSafe = /^[=+\-@]/u.test(value.trimStart()) ? `'${value}` : value;
  return /[,"\r\n]/u.test(formulaSafe)
    ? `"${formulaSafe.replaceAll('"', '""')}"`
    : formulaSafe;
}

function downloadFormat(searchParams: URLSearchParams): "JSON" | "CSV" | null {
  const entries = [...searchParams.entries()];
  if (entries.length === 0) return "JSON";
  if (entries.length !== 1 || entries[0]?.[0] !== "format") return null;
  const value = entries[0][1];
  return value === "JSON" || value === "CSV" ? value : null;
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(sortJson(value));
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => (left < right ? -1 : left === right ? 0 : 1))
      .map(([key, item]) => [key, sortJson(item)]),
  );
}
