import {
  buildRowSelectionNavigationOptions,
  PUBLIC_LEDGER_CONTRACTS,
  PUBLIC_LEDGER_SCREEN_IDS,
  type PublicDatasetRecord,
  type PublicLedgerRow,
  type PublicLedgerScreenId,
  type PublicLedgerViewModel,
  publicLedgerCell,
  publicLedgerForSection,
  publicSectionNonConclusionNotice,
  publicStatusNotice,
  type RowSelectionNavigationOptions,
} from "@gurine/ui";
import * as v from "valibot";
import {
  type AgenciesPage,
  agenciesPage,
  type CasesPage,
  type ContractsPage,
  type CorrectionsPage,
  type CoverageResponse,
  casesPage,
  contractsPage,
  correctionsPage,
  coverageResponse,
  datasetsPage,
  PUBLIC_EMPTY_RESULT_NOTICE,
  PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
  type PublicSystemStatusResponse,
  publicSystemStatusResponse,
  type SearchPage,
  type SourcesPage,
  type SuppliersPage,
  searchPage,
  sourcesPage,
  suppliersPage,
} from "./public-presentation-schemas";
import {
  compactLedgerLabel as compact,
  optionalLedgerCell as optionalCell,
  optionalLedgerStatus as optionalStatus,
  publicLedgerRow as row,
  ledgerStatus as status,
  verifiedLedgerHref as verifiedHref,
} from "./screen-helpers";

export type PublicLedgerPresentation = Readonly<{
  viewModel: PublicLedgerViewModel;
  navigationOptions: RowSelectionNavigationOptions;
}>;

export function publicLedgerPresentation(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
): PublicLedgerPresentation | undefined {
  if (screenId === "PUB-001")
    return presentation(
      screenId,
      "listPublicCases",
      casesPage,
      data,
      (page, options) => caseRows(screenId, page, options),
    );
  if (screenId === "PUB-002")
    return presentation(
      screenId,
      "searchPublicRecords",
      searchPage,
      data,
      searchRows,
    );
  if (screenId === "PUB-003")
    return presentation(
      screenId,
      "listPublicCases",
      casesPage,
      data,
      (page, options) => caseRows(screenId, page, options),
    );
  if (screenId === "PUB-007")
    return presentation(
      screenId,
      "listAgencies",
      agenciesPage,
      data,
      agencyRows,
    );
  if (screenId === "PUB-009")
    return presentation(
      screenId,
      "listSuppliers",
      suppliersPage,
      data,
      supplierRows,
    );
  if (screenId === "PUB-011")
    return presentation(
      screenId,
      "listContracts",
      contractsPage,
      data,
      contractRows,
    );
  if (screenId === "PUB-015") return coverageLedgerPresentation(data);
  if (screenId === "PUB-016")
    return presentation(
      screenId,
      "listSourceStatus",
      sourcesPage,
      data,
      sourceRows,
    );
  if (screenId === "PUB-018")
    return presentation(
      screenId,
      "listCorrections",
      correctionsPage,
      data,
      correctionRows,
    );
  if (screenId === "PUB-034") return systemStatusLedgerPresentation(data);
  return undefined;
}

export function publicFailClosedLedgerPresentation(
  screenId: string,
): PublicLedgerPresentation | undefined {
  const closedScreenId = PUBLIC_LEDGER_SCREEN_IDS.find(
    (candidate) => candidate === screenId,
  );
  if (!closedScreenId) return undefined;
  return closedLedgerPresentation(closedScreenId, {}, []);
}

export function publicDatasetPresentation(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
): readonly PublicDatasetRecord[] | undefined {
  if (screenId !== "PUB-020") return undefined;
  const response = data.listPublicDatasets;
  if (response === undefined) return undefined;
  return v
    .parse(datasetsPage, response)
    .items.map(
      ({
        id,
        title,
        description,
        format,
        license,
        updatedAt,
        redistributionNotice,
      }) => ({
        id,
        title,
        description,
        format,
        license,
        updatedAt,
        redistributionNotice,
      }),
    );
}

function presentation<TPage extends { items: readonly unknown[] }>(
  screenId: PublicLedgerScreenId,
  operationId: string,
  schema: v.BaseSchema<unknown, TPage, v.BaseIssue<unknown>>,
  data: Readonly<Record<string, unknown>>,
  rows: (
    page: TPage,
    options: RowSelectionNavigationOptions,
  ) => PublicLedgerRow[],
): PublicLedgerPresentation | undefined {
  const response = data[operationId];
  if (response === undefined) return undefined;
  const page = v.parse(schema, response);
  const navigationOptions = buildRowSelectionNavigationOptions(screenId, {
    [operationId]: page,
  });
  return closedLedgerPresentation(
    screenId,
    navigationOptions,
    rows(page, navigationOptions),
  );
}

function coverageLedgerPresentation(
  data: Readonly<Record<string, unknown>>,
): PublicLedgerPresentation | undefined {
  const response = data.getCoverage;
  if (response === undefined) return undefined;
  const coverage = v.parse(coverageResponse, response);
  const navigationOptions = buildRowSelectionNavigationOptions("PUB-015", {
    getCoverage: coverage,
  });
  return closedLedgerPresentation(
    "PUB-015",
    navigationOptions,
    coverageRows(coverage, navigationOptions),
  );
}

function systemStatusLedgerPresentation(
  data: Readonly<Record<string, unknown>>,
): PublicLedgerPresentation | undefined {
  const response = data.getPublicSystemStatus;
  if (response === undefined) return undefined;
  const systemStatus = v.parse(publicSystemStatusResponse, response);
  const navigationOptions = buildRowSelectionNavigationOptions("PUB-034", {
    getPublicSystemStatus: systemStatus,
  });
  return closedLedgerPresentation(
    "PUB-034",
    navigationOptions,
    systemSourceRows(systemStatus, navigationOptions),
  );
}

function closedLedgerPresentation(
  screenId: PublicLedgerScreenId,
  navigationOptions: RowSelectionNavigationOptions,
  rows: PublicLedgerRow[],
): PublicLedgerPresentation {
  const contract = PUBLIC_LEDGER_CONTRACTS[screenId];
  const viewModel: PublicLedgerViewModel = {
    screenId,
    sectionId: contract.sectionId,
    actionId: contract.actionId,
    collectionNotices: collectionNotices(screenId, rows),
    rows,
  };
  publicLedgerForSection(viewModel, screenId, contract.sectionId);
  return { viewModel, navigationOptions };
}

function collectionNotices(
  screenId: PublicLedgerScreenId,
  rows: readonly PublicLedgerRow[],
) {
  const notices = rows.flatMap(({ notice }) => (notice ? [notice] : []));
  if (notices.some(({ kind }) => kind === "NON_CONCLUSION"))
    return [publicSectionNonConclusionNotice()];
  if (notices.some(({ kind }) => kind === "INTERPRETATION"))
    return [
      publicStatusNotice(
        "INTERPRETATION",
        PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
      ),
    ];
  if (["PUB-001", "PUB-002", "PUB-003", "PUB-018"].includes(screenId))
    return [publicStatusNotice("NON_CONCLUSION", PUBLIC_EMPTY_RESULT_NOTICE)];
  return [
    publicStatusNotice(
      "INTERPRETATION",
      PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
    ),
  ];
}

function searchRows(page: SearchPage, options: RowSelectionNavigationOptions) {
  return page.items.map((item, index) =>
    row("PUB-002", index, {
      identifier: publicLedgerCell("id", "식별자", item.id),
      title: publicLedgerCell("title", "제목", item.title),
      summary: optionalCell("summary", "요약", item.summary ?? item.subtitle),
      kind: publicLedgerCell("resultType", "유형", item.resultType),
      status: optionalStatus("status", "상태", item.status),
      notice: searchResultNotice(item),
      metric: optionalCell("updatedAt", "갱신 시각", item.updatedAt),
      href: verifiedHref("open-result", options, [
        item.title,
        compact([item.id, item.title]),
      ]),
    }),
  );
}

function caseRows(
  screenId: "PUB-001" | "PUB-003",
  page: CasesPage,
  options: RowSelectionNavigationOptions,
) {
  return page.items.map((item, index) =>
    row(screenId, index, {
      identifier: publicLedgerCell("slug", "사건 식별자", item.slug),
      title: publicLedgerCell("title", "제목", item.title),
      summary: publicLedgerCell("summary", "요약", item.summary),
      kind: publicLedgerCell("objectType", "유형", "사례"),
      status: status("publicState", "공개 상태", item.publicState),
      notice: publicStatusNotice("NON_CONCLUSION", item.nonConclusion),
      metric: publicLedgerCell("revision", "개정본", item.revision),
      href: verifiedHref("open-case", options, [
        item.title,
        compact([item.slug, item.title]),
      ]),
    }),
  );
}

function agencyRows(
  page: AgenciesPage,
  options: RowSelectionNavigationOptions,
) {
  return page.items.map((item, index) =>
    row("PUB-007", index, {
      identifier: publicLedgerCell("id", "기관 식별자", item.id),
      title: publicLedgerCell("name", "기관명", item.name),
      summary: optionalCell("jurisdiction", "관할", item.jurisdiction),
      kind: publicLedgerCell("agencyType", "기관 유형", item.agencyType),
      status: status("status", "수집 상태", item.coverage.freshness.status),
      notice: publicStatusNotice("INTERPRETATION", item.interpretationNotice),
      metric: publicLedgerCell("caseCount", "사건 수", item.caseCounts.total),
      href: verifiedHref("open-agency", options, [item.name]),
    }),
  );
}

function supplierRows(
  page: SuppliersPage,
  options: RowSelectionNavigationOptions,
) {
  return page.items.map((item, index) =>
    row("PUB-009", index, {
      identifier: publicLedgerCell("id", "업체 식별자", item.id),
      title: publicLedgerCell("name", "업체명", item.name),
      kind: publicLedgerCell("objectType", "유형", "업체"),
      status: optionalStatus(
        "businessStatus",
        "사업자 상태",
        item.businessStatus,
      ),
      notice: publicStatusNotice("INTERPRETATION", item.interpretationNotice),
      metric: publicLedgerCell("caseCount", "사건 수", item.caseCounts.total),
      href: verifiedHref("open-supplier", options, [item.name]),
    }),
  );
}

function contractRows(
  page: ContractsPage,
  options: RowSelectionNavigationOptions,
) {
  return page.items.map((item, index) =>
    row("PUB-011", index, {
      identifier: publicLedgerCell(
        "id",
        "계약 식별자",
        item.contractNumber ?? item.id,
      ),
      title: publicLedgerCell("title", "계약명", item.title),
      summary: publicLedgerCell("agencyName", "기관명", item.agency.name),
      kind: publicLedgerCell("objectType", "유형", "계약"),
      status: status("status", "계약 상태", item.status),
      notice: publicStatusNotice("INTERPRETATION", item.interpretationNotice),
      metric: item.amount
        ? publicLedgerCell("amount", "계약 금액", item.amount.amount)
        : optionalCell("signedAt", "계약일", item.signedAt),
      href: verifiedHref("open-contract", options, [
        compact([item.contractNumber, item.title]),
        item.title,
      ]),
    }),
  );
}

function sourceRows(page: SourcesPage, options: RowSelectionNavigationOptions) {
  return sourceStatusRows("PUB-016", page.items, options);
}

function sourceStatusRows(
  screenId: "PUB-016" | "PUB-034",
  items: SourcesPage["items"],
  options: RowSelectionNavigationOptions,
) {
  return items.map((item, index) =>
    row(screenId, index, {
      identifier: publicLedgerCell("sourceId", "출처 식별자", item.sourceId),
      title: publicLedgerCell("displayName", "출처명", item.displayName),
      summary: optionalCell(
        "publicMessage",
        "공개 상태 설명",
        item.publicMessage,
      ),
      kind: publicLedgerCell("objectType", "유형", "출처"),
      status: status("status", "수집 상태", item.status),
      notice: publicStatusNotice("INTERPRETATION", item.interpretationNotice),
      metric: optionalCell(
        "lastSuccessAt",
        "마지막 수집 성공",
        item.lastSuccessAt,
      ),
      href: verifiedHref("open-source", options, [
        item.displayName,
        compact([item.sourceId, item.displayName]),
      ]),
    }),
  );
}

function coverageRows(
  coverage: CoverageResponse,
  options: RowSelectionNavigationOptions,
) {
  return coverage.sources.map((item, index) =>
    row("PUB-015", index, {
      identifier: publicLedgerCell("sourceId", "출처 식별자", item.sourceId),
      title: publicLedgerCell("displayName", "출처명", item.displayName),
      summary: publicLedgerCell("dateRange", "수집 기간", item.dateRange.label),
      kind: publicLedgerCell("objectType", "유형", "출처"),
      status: status("status", "수집 상태", item.status),
      notice: publicStatusNotice("INTERPRETATION", item.interpretationNotice),
      metric: publicLedgerCell("recordCount", "공개 기록 수", item.recordCount),
      href: verifiedHref("open-source", options, [
        item.displayName,
        compact([item.sourceId, item.displayName]),
      ]),
    }),
  );
}

function systemSourceRows(
  systemStatus: PublicSystemStatusResponse,
  options: RowSelectionNavigationOptions,
) {
  return sourceStatusRows("PUB-034", systemStatus.sourceStatus, options);
}

function correctionRows(
  page: CorrectionsPage,
  options: RowSelectionNavigationOptions,
) {
  return page.items.map((item, index) =>
    row("PUB-018", index, {
      identifier: publicLedgerCell("id", "정정 식별자", item.id),
      title: publicLedgerCell("summary", "정정 요약", item.summary),
      summary: publicLedgerCell("reason", "정정 사유", item.reason),
      kind: publicLedgerCell("objectType", "유형", "정정"),
      status: status("publicState", "공개 상태", item.publicState),
      notice: publicStatusNotice("NON_CONCLUSION", item.nonConclusion),
      metric: publicLedgerCell(
        "revision",
        "대상 개정본",
        item.targetRevision ?? item.sourceRevision,
      ),
      href: verifiedHref("open-correction", options, [item.summary]),
    }),
  );
}

function searchResultNotice(item: SearchPage["items"][number]) {
  if (item.resultType === "CASE" || item.resultType === "CORRECTION") {
    if (item.nonConclusion === null || item.interpretationNotice !== null)
      throw new Error(`검색 상태 고지 계약 불일치: ${item.resultType}`);
    return publicStatusNotice("NON_CONCLUSION", item.nonConclusion);
  }
  if (
    item.resultType === "AGENCY" ||
    item.resultType === "SUPPLIER" ||
    item.resultType === "CONTRACT" ||
    item.resultType === "SOURCE"
  ) {
    if (item.nonConclusion !== null || item.interpretationNotice === null)
      throw new Error(`검색 상태 해석 계약 불일치: ${item.resultType}`);
    return publicStatusNotice("INTERPRETATION", item.interpretationNotice);
  }
  if (item.nonConclusion !== null || item.interpretationNotice !== null)
    throw new Error(`검색 비적용 고지 계약 불일치: ${item.resultType}`);
  return null;
}
