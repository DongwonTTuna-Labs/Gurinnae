export type Cas010Metric = {
  readonly visualizationId: string;
  readonly title: string;
  readonly formattedValue: string;
  readonly narrativeAlternative: string;
  readonly tableAlternative: {
    readonly caption: string;
    readonly headers: readonly string[];
    readonly rows: readonly (readonly string[])[];
    readonly dataSha256: string;
  };
};

export type Cas010ViewModel = {
  readonly schemaVersion: "analysis-vm.cas-010.v2";
  readonly screenId: "CAS-010";
  readonly caseId: string | null;
  readonly screenState: string | null;
  readonly runs: readonly Record<string, unknown>[];
  readonly filters: Record<string, unknown> | null;
  readonly suggestions: readonly Record<string, unknown>[];
  readonly budget: Record<string, unknown> | null;
  readonly visualizations: readonly Cas010Metric[];
  readonly visualizationSetSha256: string | null;
  readonly viewModelSha256: string | null;
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
const text = (value: unknown): string | null =>
  typeof value === "string" && value.length > 0 ? value : null;
const records = (value: unknown): readonly Record<string, unknown>[] =>
  Array.isArray(value)
    ? value.flatMap((item) => {
        const row = record(item);
        return row ? [row] : [];
      })
    : [];

function metric(value: unknown): Cas010Metric | null {
  const item = record(value);
  const table = record(item?.tableAlternative);
  const visualizationId = text(item?.visualizationId);
  const title = text(item?.title);
  const formattedValue = text(item?.formattedValue);
  const narrativeAlternative = text(item?.narrativeAlternative);
  const dataSha256 = text(table?.dataSha256);
  if (
    item?.kind !== "METRIC" ||
    !visualizationId ||
    !title ||
    !formattedValue ||
    !narrativeAlternative ||
    !table ||
    !dataSha256
  )
    return null;
  return {
    visualizationId,
    title,
    formattedValue,
    narrativeAlternative,
    tableAlternative: {
      caption: text(table.caption) ?? title,
      headers: Array.isArray(table.headers)
        ? table.headers.filter(
            (header): header is string => typeof header === "string",
          )
        : [],
      rows: Array.isArray(table.rows)
        ? table.rows.map((row) =>
            Array.isArray(row)
              ? row.map((cell) =>
                  typeof cell === "string" ? cell : String(cell),
                )
              : [],
          )
        : [],
      dataSha256,
    },
  };
}

/** Unwraps the reduced listCaseAgentRuns authority envelope only. */
export function toCas010ViewModel(
  data: Record<string, unknown>,
): Cas010ViewModel | null {
  const operation = record(data.listCaseAgentRuns) ?? record(data);
  const envelope = record(operation?.data) ?? operation;
  const vm = record(operation?.analysisVm) ?? record(envelope?.analysisVm);
  if (
    vm?.schemaVersion !== "analysis-vm.cas-010.v2" ||
    vm.screenId !== "CAS-010"
  ) {
    // The v13 transport contract is also valid without the optional
    // server-side projection. Keep the typed screen usable from the closed
    // CaseAgentRunsPage DTO instead of turning a valid response into empty.
    const items = records(envelope?.items);
    return {
      schemaVersion: "analysis-vm.cas-010.v2",
      screenId: "CAS-010",
      caseId: text(envelope?.caseId),
      screenState: items.length > 0 ? "saved" : "empty",
      runs: items,
      filters: record(envelope?.appliedFilters),
      suggestions: [],
      budget: null,
      visualizations: [],
      visualizationSetSha256: null,
      viewModelSha256: null,
    };
  }
  const visualizationSet = record(vm.visualizations);
  const visualItems = visualizationSet?.visualizations;
  return {
    schemaVersion: "analysis-vm.cas-010.v2",
    screenId: "CAS-010",
    caseId: text(vm.caseId) ?? text(envelope?.caseId),
    screenState: text(vm.screenState) ?? text(envelope?.status),
    runs: records(vm.runs),
    filters: record(vm.filters),
    suggestions: records(vm.suggestions),
    budget: record(vm.budget),
    visualizations: Array.isArray(visualItems)
      ? visualItems
          .map(metric)
          .filter((item): item is Cas010Metric => item !== null)
      : [],
    visualizationSetSha256: text(visualizationSet?.visualizationSetSha256),
    viewModelSha256: text(vm.viewModelSha256),
  };
}
