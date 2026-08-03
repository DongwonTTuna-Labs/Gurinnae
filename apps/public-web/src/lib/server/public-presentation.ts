import {
  buildRowSelectionNavigationOptions,
  PUBLIC_LEDGER_CONTRACTS,
  type PublicDatasetRecord,
  type PublicLedgerRow,
  type PublicLedgerScreenId,
  type PublicLedgerViewModel,
  publicLedgerCell,
  publicLedgerForSection,
  type RowSelectionNavigationOptions,
} from "@gurine/ui";
import * as v from "valibot";
import {
  type AgenciesPage,
  agenciesPage,
  type CasesPage,
  type ContractsPage,
  type CorrectionsPage,
  casesPage,
  contractsPage,
  correctionsPage,
  datasetsPage,
  type SearchPage,
  type SuppliersPage,
  searchPage,
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
  if (screenId === "PUB-018")
    return presentation(
      screenId,
      "listCorrections",
      correctionsPage,
      data,
      correctionRows,
    );
  return undefined;
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
    .items.map(({ id, title, description, format, license, updatedAt }) => ({
      id,
      title,
      description,
      format,
      license,
      updatedAt,
    }));
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
  const contract = PUBLIC_LEDGER_CONTRACTS[screenId];
  const viewModel: PublicLedgerViewModel = {
    screenId,
    sectionId: contract.sectionId,
    actionId: contract.actionId,
    rows: rows(page, navigationOptions),
  };
  publicLedgerForSection(viewModel, screenId, contract.sectionId);
  return { viewModel, navigationOptions };
}

function searchRows(page: SearchPage, options: RowSelectionNavigationOptions) {
  return page.items.map((item, index) =>
    row("PUB-002", index, {
      identifier: publicLedgerCell("id", "식별자", item.id),
      title: publicLedgerCell("title", "제목", item.title),
      summary: optionalCell("summary", "요약", item.summary ?? item.subtitle),
      kind: publicLedgerCell("resultType", "유형", item.resultType),
      status: optionalStatus("status", "상태", item.status),
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
      metric: publicLedgerCell(
        "revision",
        "대상 개정본",
        item.targetRevision ?? item.sourceRevision,
      ),
      href: verifiedHref("open-correction", options, [item.summary]),
    }),
  );
}
