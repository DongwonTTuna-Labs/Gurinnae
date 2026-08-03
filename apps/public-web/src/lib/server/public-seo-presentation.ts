import type { PublicSeoViewModel } from "@gurine/ui";
import * as v from "valibot";
import {
  agenciesPage,
  casesPage,
  contractsPage,
  correctionsPage,
  coverageResponse,
  datasetsPage,
  PUBLIC_EMPTY_RESULT_NOTICE,
  PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
  PUBLIC_REDISTRIBUTION_NOTICE,
  publicSystemStatusResponse,
  searchPage,
  sourcesPage,
  suppliersPage,
} from "./public-presentation-schemas";
import { publicStatusPresentation } from "./public-status-presentation";

const SEO_OPERATION_BY_SCREEN: Readonly<Record<string, string>> = {
  "PUB-002": "searchPublicRecords",
  "PUB-003": "listPublicCases",
  "PUB-004": "getPublicCase",
  "PUB-005": "getPublicCaseRevision",
  "PUB-006": "getCaseReproducibility",
  "PUB-007": "listAgencies",
  "PUB-008": "getAgency",
  "PUB-009": "listSuppliers",
  "PUB-010": "getSupplier",
  "PUB-011": "listContracts",
  "PUB-012": "getContract",
  "PUB-014": "listRuleCases",
  "PUB-016": "listSourceStatus",
  "PUB-017": "getSource",
  "PUB-018": "listCorrections",
  "PUB-019": "getCorrection",
  "PUB-020": "listPublicDatasets",
};

export function publicSeoOperationIds(screenId: string): readonly string[] {
  if (screenId === "PUB-001")
    return ["listPublicCases", "listCorrections", "listSourceStatus"];
  if (screenId === "PUB-015") return ["getCoverage"];
  if (screenId === "PUB-034") return ["getPublicSystemStatus"];
  const operationId = SEO_OPERATION_BY_SCREEN[screenId];
  return operationId ? [operationId] : [];
}

const PUBLIC_STATE_ORDER = new Map(
  [
    "PUBLISHED_ANOMALY",
    "PUBLISHED_EXPLAINED",
    "OFFICIALLY_CONFIRMED",
    "CORRECTED",
    "RETRACTED",
    "TEMPORARILY_RESTRICTED",
  ].map((state, index) => [state, index]),
);

export function publicSeoPresentation(
  screenId: string,
  screenTitle: string,
  data: Readonly<Record<string, unknown>>,
  requestUrl: URL,
): PublicSeoViewModel | undefined {
  if (screenId === "PUB-001") return homeSeo(screenTitle, data, requestUrl);
  if (screenId === "PUB-015") return coverageSeo(screenTitle, data, requestUrl);
  if (screenId === "PUB-034")
    return systemStatusSeo(screenTitle, data, requestUrl);
  const [operationId] = publicSeoOperationIds(screenId);
  if (!operationId) return undefined;
  const response = data[operationId];
  if (screenId === "PUB-002" && response === undefined)
    return awaitingSearchSeo(screenTitle, requestUrl);
  if (response === undefined)
    throw new Error(`공개 SEO 주 응답 누락: ${operationId}`);
  const envelope = record(response, operationId);
  const seo = validatedSeo(envelope.seo, requestUrl, operationId);
  requireSeoNotices(
    seo,
    expectedNotices(screenId, data, response),
    operationId,
  );
  return seo;
}

export function publicFailClosedSeoPresentation(
  screenId: string,
  screenTitle: string,
  requestUrl: URL,
): PublicSeoViewModel | undefined {
  const description = failClosedNotice(screenId);
  if (!description) return undefined;
  return {
    title: `${screenTitle} · 구린네`,
    description,
    openGraphDescription: description,
    canonicalUrl: new URL(requestUrl.pathname, requestUrl.origin).toString(),
    robots: "index,follow",
  };
}

function awaitingSearchSeo(
  screenTitle: string,
  requestUrl: URL,
): PublicSeoViewModel {
  const description =
    "검색어 입력 대기. 공개 기록의 확인 상태와 비확정 고지를 함께 확인합니다.";
  return {
    title: `${screenTitle} · 구린네`,
    description,
    openGraphDescription: description,
    canonicalUrl: new URL(requestUrl.pathname, requestUrl.origin).toString(),
    robots: "index,follow",
  };
}

function expectedNotices(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
  response: unknown,
): readonly string[] {
  if (screenId === "PUB-002") {
    const page = v.parse(searchPage, response);
    const notices = page.items.flatMap((item) =>
      [item.nonConclusion, item.interpretationNotice].flatMap((notice) =>
        notice === null ? [] : [notice.trim()],
      ),
    );
    return page.items.length === 0 ? [PUBLIC_EMPTY_RESULT_NOTICE] : notices;
  }
  if (screenId === "PUB-003" || screenId === "PUB-014") {
    const notices = v
      .parse(casesPage, response)
      .items.map(({ nonConclusion }) => nonConclusion.trim());
    return notices.length === 0 ? [PUBLIC_EMPTY_RESULT_NOTICE] : notices;
  }
  if (screenId === "PUB-007") {
    const notices = v
      .parse(agenciesPage, response)
      .items.map(({ interpretationNotice }) => interpretationNotice.trim());
    return operationalNotices(notices);
  }
  if (screenId === "PUB-009") {
    const notices = v
      .parse(suppliersPage, response)
      .items.map(({ interpretationNotice }) => interpretationNotice.trim());
    return operationalNotices(notices);
  }
  if (screenId === "PUB-011") {
    const notices = v
      .parse(contractsPage, response)
      .items.map(({ interpretationNotice }) => interpretationNotice.trim());
    return operationalNotices(notices);
  }
  if (screenId === "PUB-016") {
    const notices = v
      .parse(sourcesPage, response)
      .items.map(({ interpretationNotice }) => interpretationNotice.trim());
    return operationalNotices(notices);
  }
  if (screenId === "PUB-018") {
    const notices = v
      .parse(correctionsPage, response)
      .items.map(({ nonConclusion }) => nonConclusion.trim());
    return notices.length === 0 ? [PUBLIC_EMPTY_RESULT_NOTICE] : notices;
  }
  if (screenId === "PUB-020") {
    const notices = v
      .parse(datasetsPage, response)
      .items.map(({ redistributionNotice }) => redistributionNotice);
    return notices.length === 0 ? [PUBLIC_REDISTRIBUTION_NOTICE] : notices;
  }
  const notice = publicStatusPresentation(screenId, data);
  return notice ? [notice.notice.text] : [];
}

function homeSeo(
  screenTitle: string,
  data: Readonly<Record<string, unknown>>,
  requestUrl: URL,
): PublicSeoViewModel {
  const cases = requiredResponse(data, "listPublicCases");
  const corrections = requiredResponse(data, "listCorrections");
  const sources = requiredResponse(data, "listSourceStatus");
  const casePage = v.parse(casesPage, cases);
  const correctionPage = v.parse(correctionsPage, corrections);
  const sourcePage = v.parse(sourcesPage, sources);
  const notices: Array<{
    state: string;
    kind: 0 | 1 | 2;
    text: string;
  }> = [];
  if (casePage.items.length === 0) {
    notices.push({
      state: "PUBLISHED_ANOMALY",
      kind: 0,
      text: PUBLIC_EMPTY_RESULT_NOTICE,
    });
  } else {
    for (const item of casePage.items)
      notices.push({
        state: item.publicState,
        kind: 0,
        text: item.nonConclusion.trim(),
      });
  }
  if (correctionPage.items.length === 0) {
    notices.push({
      state: "CORRECTED",
      kind: 1,
      text: PUBLIC_EMPTY_RESULT_NOTICE,
    });
  } else {
    for (const item of correctionPage.items)
      notices.push({
        state: item.publicState,
        kind: 1,
        text: item.nonConclusion.trim(),
      });
  }
  if (sourcePage.items.length > 0) {
    for (const item of sourcePage.items)
      notices.push({
        state: item.status,
        kind: 2,
        text: item.interpretationNotice.trim(),
      });
  }
  requirePageAuthority(
    casePage,
    [
      ...(casePage.items.length === 0
        ? [PUBLIC_EMPTY_RESULT_NOTICE]
        : casePage.items.map(({ nonConclusion }) => nonConclusion)),
    ],
    "listPublicCases",
  );
  requirePageAuthority(
    correctionPage,
    [
      ...(correctionPage.items.length === 0
        ? [PUBLIC_EMPTY_RESULT_NOTICE]
        : correctionPage.items.map(({ nonConclusion }) => nonConclusion)),
    ],
    "listCorrections",
  );
  requirePageAuthority(
    sourcePage,
    operationalNotices(
      sourcePage.items.map(({ interpretationNotice }) => interpretationNotice),
    ),
    "listSourceStatus",
  );
  notices.sort(
    (left, right) =>
      homeNoticeOrder(left) - homeNoticeOrder(right) || left.kind - right.kind,
  );
  const unique = [...new Set(notices.map(({ text }) => text))];
  const description = unique.join(" · ");
  return {
    title: `${screenTitle} · 구린네`,
    description,
    openGraphDescription: description,
    canonicalUrl: new URL(requestUrl.pathname, requestUrl.origin).toString(),
    robots: "index,follow",
  };
}

function homeNoticeOrder(notice: { state: string; kind: 0 | 1 | 2 }) {
  return notice.kind === 2 ? 20 : stateOrder(notice.state);
}

function coverageSeo(
  screenTitle: string,
  data: Readonly<Record<string, unknown>>,
  requestUrl: URL,
): PublicSeoViewModel {
  const response = requiredResponse(data, "getCoverage");
  const notices = v
    .parse(coverageResponse, response)
    .sources.map(({ interpretationNotice }) => interpretationNotice.trim());
  return sourceCollectionSeo(
    screenTitle,
    requestUrl,
    operationalNotices(notices),
  );
}

function systemStatusSeo(
  screenTitle: string,
  data: Readonly<Record<string, unknown>>,
  requestUrl: URL,
): PublicSeoViewModel {
  const response = requiredResponse(data, "getPublicSystemStatus");
  const notices = v
    .parse(publicSystemStatusResponse, response)
    .sourceStatus.map(({ interpretationNotice }) =>
      interpretationNotice.trim(),
    );
  return sourceCollectionSeo(
    screenTitle,
    requestUrl,
    operationalNotices(notices),
  );
}

function sourceCollectionSeo(
  screenTitle: string,
  requestUrl: URL,
  sourceNotices: readonly string[],
): PublicSeoViewModel {
  const notices = [...new Set(sourceNotices)];
  const description = notices.join(" · ");
  return {
    title: `${screenTitle} · 구린네`,
    description,
    openGraphDescription: description,
    canonicalUrl: new URL(requestUrl.pathname, requestUrl.origin).toString(),
    robots: "index,follow",
  };
}

function requiredResponse(
  data: Readonly<Record<string, unknown>>,
  operationId: string,
): unknown {
  const response = data[operationId];
  if (response === undefined)
    throw new Error(`공개 SEO 주 응답 누락: ${operationId}`);
  return response;
}

function operationalNotices(notices: readonly string[]): readonly string[] {
  return notices.length === 0
    ? [PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE]
    : notices;
}

function requirePageAuthority(
  page: Readonly<{
    seo: Readonly<{ description: string; openGraphDescription: string }>;
  }>,
  notices: readonly string[],
  operationId: string,
) {
  if (page.seo.description !== page.seo.openGraphDescription)
    throw new Error(`공개 SEO 설명 계약 불일치: ${operationId}`);
  requireSeoNotices(page.seo, notices, operationId);
}

function requireSeoNotices(
  seo: Readonly<{ description: string; openGraphDescription: string }>,
  notices: readonly string[],
  operationId: string,
) {
  for (const notice of [...new Set(notices)]) {
    if (
      !seo.description.includes(notice) ||
      !seo.openGraphDescription.includes(notice)
    )
      throw new Error(`공개 SEO 상태 고지 누락: ${operationId}`);
  }
}

function failClosedNotice(screenId: string): string | undefined {
  if (
    [
      "PUB-001",
      "PUB-002",
      "PUB-003",
      "PUB-004",
      "PUB-005",
      "PUB-006",
      "PUB-014",
      "PUB-018",
      "PUB-019",
    ].includes(screenId)
  )
    return PUBLIC_EMPTY_RESULT_NOTICE;
  if (
    [
      "PUB-007",
      "PUB-008",
      "PUB-009",
      "PUB-010",
      "PUB-011",
      "PUB-012",
      "PUB-015",
      "PUB-016",
      "PUB-017",
      "PUB-034",
    ].includes(screenId)
  )
    return PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE;
  if (screenId === "PUB-020") return PUBLIC_REDISTRIBUTION_NOTICE;
  return undefined;
}

function validatedSeo(
  value: unknown,
  requestUrl: URL,
  operationId: string,
): PublicSeoViewModel {
  const seo = record(value, `${operationId}.seo`);
  const title = nonEmptyText(seo.title, `${operationId}.seo.title`);
  const description = nonEmptyText(
    seo.description,
    `${operationId}.seo.description`,
  );
  const openGraphDescription = nonEmptyText(
    seo.openGraphDescription,
    `${operationId}.seo.openGraphDescription`,
  );
  if (description !== openGraphDescription)
    throw new Error(`공개 SEO 설명 계약 불일치: ${operationId}`);
  const robots = nonEmptyText(seo.robots, `${operationId}.seo.robots`);
  if (robots !== "index,follow")
    throw new Error(`공개 SEO robots 계약 불일치: ${operationId}`);
  const canonicalUrl = new URL(
    nonEmptyText(seo.canonicalUrl, `${operationId}.seo.canonicalUrl`),
    requestUrl.origin,
  );
  if (canonicalUrl.origin !== requestUrl.origin)
    throw new Error(`공개 SEO canonical origin 불일치: ${operationId}`);
  if (
    canonicalUrl.pathname !== requestUrl.pathname ||
    canonicalUrl.search !== "" ||
    canonicalUrl.hash !== ""
  )
    throw new Error(`공개 SEO canonical 경로 불일치: ${operationId}`);
  return {
    title,
    description,
    openGraphDescription,
    canonicalUrl: canonicalUrl.toString(),
    robots,
  };
}

function stateOrder(state: string): number {
  const order = PUBLIC_STATE_ORDER.get(state);
  if (order === undefined)
    throw new Error(`홈 공개 상태 SEO 계약 불일치: ${state}`);
  return order;
}

function record(value: unknown, source: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error(`공개 SEO 응답 계약 불일치: ${source}`);
  return value as Record<string, unknown>;
}

function nonEmptyText(value: unknown, source: string): string {
  if (typeof value !== "string" || !value.trim())
    throw new Error(`공개 SEO 응답 계약 불일치: ${source}`);
  return value.trim();
}
