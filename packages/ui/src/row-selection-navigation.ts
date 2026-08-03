export type RowSelectionNavigationOption = Readonly<{
  label: string;
  href: string;
}>;

export type RowSelectionNavigationOptions = Readonly<
  Record<string, readonly RowSelectionNavigationOption[]>
>;

type OperationData = Readonly<Record<string, unknown>>;
type OptionBuilder = (data: OperationData) => RowSelectionNavigationOption[];

const PUBLIC_DETAIL_PATHS = {
  agency: /^\/agencies\/[A-Za-z0-9._~-]+\/?$/,
  case: /^\/cases\/[A-Za-z0-9._~-]+\/?$/,
  contract: /^\/contracts\/[A-Za-z0-9._~-]+\/?$/,
  correction: /^\/corrections\/[A-Za-z0-9._~-]+\/?$/,
  dataset: /^\/data\/?$/,
  rule: /^\/methodology\/rules\/[A-Za-z0-9._~-]+\/?$/,
  source: /^\/sources\/[A-Za-z0-9._~-]+\/?$/,
  supplier: /^\/suppliers\/[A-Za-z0-9._~-]+\/?$/,
} as const;

const INTERNAL_PATHS = [
  /^\/internal\/(?:account|audit|cases|corrections|dashboard|my-work|notifications|operations|review|rules|search|signals|sources)\/?$/,
  /^\/internal\/admin\/(?:roles|users)\/?$/,
  /^\/internal\/admin\/users\/[A-Za-z0-9._~-]+\/?$/,
  /^\/internal\/cases\/[A-Za-z0-9._~-]+\/(?:agent-runs|audit|claims|corrections|evidence|hypotheses|overview|preview|responses|review|signals|timeline)\/?$/,
  /^\/internal\/cases\/[A-Za-z0-9._~-]+\/(?:agent-runs|evidence)\/[A-Za-z0-9._~-]+\/?$/,
  /^\/internal\/cases\/[A-Za-z0-9._~-]+\/responses\/new\/?$/,
  /^\/internal\/corrections\/[A-Za-z0-9._~-]+\/?$/,
  /^\/internal\/operations\/(?:budgets|jobs|kill-switches|providers)\/?$/,
  /^\/internal\/operations\/jobs\/[A-Za-z0-9._~-]+\/?$/,
  /^\/internal\/review\/[A-Za-z0-9._~-]+(?:\/publish)?\/?$/,
  /^\/internal\/rules\/[A-Za-z0-9._~-]+\/versions\/[A-Za-z0-9._~-]+(?:\/(?:activation|evaluation))?\/?$/,
  /^\/internal\/signals\/[A-Za-z0-9._~-]+\/?$/,
  /^\/internal\/sources\/[A-Za-z0-9._~-]+(?:\/(?:backfill|runs|schema-drift))?\/?$/,
  /^\/internal\/sources\/[A-Za-z0-9._~-]+\/runs\/[A-Za-z0-9._~-]+\/?$/,
] as const;

const builders: Readonly<
  Record<string, Readonly<{ actionId: string; build: OptionBuilder }>>
> = {
  "PUB-001": {
    actionId: "open-case",
    build: (data) =>
      hrefItems(data, "listPublicCases", "title", [PUBLIC_DETAIL_PATHS.case]),
  },
  "PUB-002": { actionId: "open-result", build: searchResultOptions },
  "PUB-003": {
    actionId: "open-case",
    build: (data) =>
      hrefItems(data, "listPublicCases", "title", [PUBLIC_DETAIL_PATHS.case]),
  },
  "PUB-007": {
    actionId: "open-agency",
    build: (data) =>
      hrefItems(data, "listAgencies", "name", [PUBLIC_DETAIL_PATHS.agency]),
  },
  "PUB-008": {
    actionId: "view-contract",
    build: (data) => contractItems(data, "listAgencyContracts"),
  },
  "PUB-009": {
    actionId: "open-supplier",
    build: (data) =>
      hrefItems(data, "listSuppliers", "name", [PUBLIC_DETAIL_PATHS.supplier]),
  },
  "PUB-010": {
    actionId: "view-contract",
    build: (data) => contractItems(data, "listSupplierContracts"),
  },
  "PUB-011": {
    actionId: "open-contract",
    build: (data) => contractItems(data, "listContracts"),
  },
  "PUB-012": { actionId: "open-source", build: sourceDocumentOptions },
  "PUB-013": { actionId: "open-rule", build: publicRuleOptions },
  "PUB-015": { actionId: "open-source", build: coverageSourceOptions },
  "PUB-016": { actionId: "open-source", build: sourceStatusOptions },
  "PUB-018": {
    actionId: "open-correction",
    build: (data) =>
      hrefItems(data, "listCorrections", "summary", [
        PUBLIC_DETAIL_PATHS.correction,
      ]),
  },
  "PUB-019": { actionId: "open-case", build: correctionCaseOptions },
  "INT-001": { actionId: "open-task", build: dashboardTaskOptions },
  "INT-004": { actionId: "open", build: notificationOptions },
  "RULE-001": { actionId: "open-rule", build: internalRuleOptions },
};

/**
 * Reduces operation DTOs to the only row-selection data the browser needs.
 * Unknown screens, invalid identifiers and non-allowlisted destinations stay
 * absent so callers can fail closed instead of rendering inert actions.
 */
export function buildRowSelectionNavigationOptions(
  screenId: string,
  data: OperationData,
): RowSelectionNavigationOptions {
  const definition = builders[screenId];
  if (!definition) return {};
  const options = uniqueOptions(definition.build(data));
  return options.length > 0 ? { [definition.actionId]: options } : {};
}

function contractItems(data: OperationData, operationId: string) {
  return itemRecords(data, operationId).flatMap((item) => {
    const label = compactLabel([item.contractNumber, item.title]);
    const href = allowlistedPath(item.href, [PUBLIC_DETAIL_PATHS.contract]);
    return label && href ? [{ label, href }] : [];
  });
}

function hrefItems(
  data: OperationData,
  operationId: string,
  labelField: string,
  paths: readonly RegExp[],
) {
  return itemRecords(data, operationId).flatMap((item) => {
    const label = compactLabel([item[labelField]]);
    const href = allowlistedPath(item.href, paths);
    return label && href ? [{ label, href }] : [];
  });
}

function searchResultOptions(data: OperationData) {
  return hrefItems(data, "searchPublicRecords", "title", [
    PUBLIC_DETAIL_PATHS.agency,
    PUBLIC_DETAIL_PATHS.case,
    PUBLIC_DETAIL_PATHS.contract,
    PUBLIC_DETAIL_PATHS.correction,
    PUBLIC_DETAIL_PATHS.dataset,
    PUBLIC_DETAIL_PATHS.rule,
    PUBLIC_DETAIL_PATHS.source,
    PUBLIC_DETAIL_PATHS.supplier,
  ]);
}

function sourceDocumentOptions(data: OperationData) {
  const contract = record(data.getContract);
  return array(contract?.sourceDocuments).flatMap((value) => {
    const item = record(value);
    const label = compactLabel([item?.sourceId, item?.externalId]);
    const href = httpsHref(item?.canonicalUrl);
    return label && href ? [{ label, href }] : [];
  });
}

function publicRuleOptions(data: OperationData) {
  return itemRecords(data, "listRules").flatMap((item) => {
    const segment = safeSegment(item.ruleId);
    const label = compactLabel([item.name, item.activeVersion]);
    return segment && label
      ? [{ label, href: `/methodology/rules/${segment}` }]
      : [];
  });
}

function coverageSourceOptions(data: OperationData) {
  const coverage = record(data.getCoverage);
  return sourceOptions(array(coverage?.sources));
}

function sourceStatusOptions(data: OperationData) {
  return sourceOptions(itemRecords(data, "listSourceStatus"));
}

function sourceOptions(values: readonly unknown[]) {
  return values.flatMap((value) => {
    const item = record(value);
    const segment = safeSegment(item?.sourceId);
    const label = compactLabel([item?.displayName]);
    return segment && label ? [{ label, href: `/sources/${segment}` }] : [];
  });
}

function correctionCaseOptions(data: OperationData) {
  const response = record(data.getCorrection);
  const correction = record(response?.data);
  const segment = safeSegment(correction?.caseSlug);
  const label = compactLabel([correction?.caseSlug]);
  return segment && label ? [{ label, href: `/cases/${segment}` }] : [];
}

function dashboardTaskOptions(data: OperationData) {
  const dashboard = record(data.getInternalDashboard);
  return [
    ...array(dashboard?.myTasks),
    ...array(dashboard?.overdueTasks),
  ].flatMap((value) => internalHrefOption(value, "title"));
}

function notificationOptions(data: OperationData) {
  return itemRecords(data, "listInternalNotifications").flatMap((item) =>
    internalHrefOption(item, "title"),
  );
}

function internalRuleOptions(data: OperationData) {
  return itemRecords(data, "listInternalRules").flatMap((item) => {
    const ruleId = safeSegment(item.ruleId);
    const version = safeSegment(item.version);
    const label = compactLabel([item.name, item.version]);
    return ruleId && version && label
      ? [
          {
            label,
            href: `/internal/rules/${ruleId}/versions/${version}`,
          },
        ]
      : [];
  });
}

function internalHrefOption(value: unknown, labelField: string) {
  const item = record(value);
  const label = compactLabel([item?.[labelField]]);
  const href = allowlistedPath(item?.href, INTERNAL_PATHS, true);
  return label && href ? [{ label, href }] : [];
}

function itemRecords(data: OperationData, operationId: string) {
  const page = record(data[operationId]);
  return array(page?.items).flatMap((value) => {
    const item = record(value);
    return item ? [item] : [];
  });
}

function allowlistedPath(
  value: unknown,
  patterns: readonly RegExp[],
  allowSuffix = false,
) {
  if (
    typeof value !== "string" ||
    !value.startsWith("/") ||
    value.startsWith("//")
  )
    return undefined;
  try {
    const parsed = new URL(value, "https://gurine.invalid");
    if (parsed.origin !== "https://gurine.invalid") return undefined;
    const suffixIndex = value.search(/[?#]/);
    const suppliedPath =
      suffixIndex === -1 ? value : value.slice(0, suffixIndex);
    if (suppliedPath !== parsed.pathname) return undefined;
    if (!allowSuffix && (parsed.search || parsed.hash)) return undefined;
    if (!patterns.some((pattern) => pattern.test(parsed.pathname)))
      return undefined;
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return undefined;
  }
}

function httpsHref(value: unknown) {
  if (typeof value !== "string") return undefined;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" && !parsed.username && !parsed.password
      ? parsed.href
      : undefined;
  } catch {
    return undefined;
  }
}

function safeSegment(value: unknown) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 &&
    trimmed.length <= 128 &&
    /^[A-Za-z0-9._~-]+$/.test(trimmed)
    ? encodeURIComponent(trimmed)
    : undefined;
}

function compactLabel(values: readonly unknown[]) {
  const parts = values.flatMap((value) => {
    if (typeof value !== "string") return [];
    const normalized = value.replaceAll(/\s+/g, " ").trim();
    const hasControl = Array.from(normalized).some((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      return codePoint < 32 || codePoint === 127;
    });
    return normalized && !hasControl ? [normalized] : [];
  });
  const label = parts.join(" · ");
  return label ? label.slice(0, 120) : undefined;
}

function uniqueOptions(options: readonly RowSelectionNavigationOption[]) {
  const seen = new Set<string>();
  return options.filter(({ href }) => {
    if (seen.has(href)) return false;
    seen.add(href);
    return true;
  });
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function array(value: unknown): readonly unknown[] {
  return Array.isArray(value) ? value : [];
}
