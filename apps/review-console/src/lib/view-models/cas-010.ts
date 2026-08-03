export type Cas010Metric = {
  readonly visualizationId: string;
  readonly title: string;
  readonly value: number;
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
  readonly caseId: string;
  readonly screenState: string;
  readonly runs: readonly Record<string, unknown>[];
  readonly filters: Record<string, unknown> | null;
  readonly suggestions: readonly Record<string, unknown>[];
  readonly budget: Record<string, unknown> | null;
  readonly visualizations: readonly Cas010Metric[];
  readonly visualizationSetSha256: string;
  readonly viewModelSha256: string;
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;

const string = (value: unknown): string | null =>
  typeof value === "string" && value.length > 0 ? value : null;

const number = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

const stringRows = (value: unknown): readonly (readonly string[])[] =>
  Array.isArray(value)
    ? value.map((row) =>
        Array.isArray(row)
          ? row.map((cell) => (typeof cell === "string" ? cell : String(cell)))
          : [],
      )
    : [];

function metric(value: unknown): Cas010Metric | null {
  const item = record(value);
  const table = record(item?.tableAlternative);
  const id = string(item?.visualizationId);
  if (item?.kind !== "METRIC" || !id || !table) return null;
  const title = string(item.title);
  const formattedValue = string(item.formattedValue);
  const narrative = string(item.narrativeAlternative);
  const dataSha256 = string(table.dataSha256);
  if (!title || !formattedValue || !narrative || !dataSha256) return null;
  return {
    visualizationId: id,
    title,
    value: number(item.value) ?? 0,
    formattedValue,
    narrativeAlternative: narrative,
    tableAlternative: {
      caption: string(table.caption) ?? title,
      headers: Array.isArray(table.headers)
        ? table.headers.filter(
            (header): header is string => typeof header === "string",
          )
        : [],
      rows: stringRows(table.rows),
      dataSha256,
    },
  };
}

/** Closed CAS-010 projection; missing authority data remains explicitly unknown. */
export function toCas010ViewModel(
  data: Record<string, unknown>,
): Cas010ViewModel | null {
  const operation = record(data.listCaseAgentRuns) ?? record(data);
  const response = record(operation?.data) ?? operation;
  const vm = record(operation?.analysisVm) ?? record(response?.analysisVm);
  if (
    vm?.schemaVersion !== "analysis-vm.cas-010.v2" ||
    vm.screenId !== "CAS-010"
  ) {
    const items = Array.isArray(response?.items)
      ? response.items.flatMap((item) => {
          const row = record(item);
          return row ? [row] : [];
        })
      : [];
    return {
      schemaVersion: "analysis-vm.cas-010.v2",
      screenId: "CAS-010",
      caseId: string(response?.caseId) ?? "",
      screenState: items.length > 0 ? "saved" : "empty",
      runs: items,
      filters: record(response?.appliedFilters),
      suggestions: [],
      budget: null,
      visualizations: [],
      visualizationSetSha256: "",
      viewModelSha256: "",
    };
  }
  const visualItems = record(vm.visualizations)?.visualizations;
  const visualizations = Array.isArray(visualItems)
    ? visualItems
        .map(metric)
        .filter((item): item is Cas010Metric => item !== null)
    : [];
  const runsSource = Array.isArray(vm.runs)
    ? vm.runs
    : (operation?.items ?? response?.items);
  const runs = Array.isArray(runsSource)
    ? runsSource.flatMap((run) => {
        const row = record(run);
        return row ? [row] : [];
      })
    : [];
  const items = Array.isArray(operation?.items)
    ? operation.items
    : response?.items;
  const suggestions = Array.isArray(items)
    ? items.flatMap((item) => {
        const row = record(item);
        const counts = record(row?.suggestionCounts);
        return counts ? [counts] : [];
      })
    : [];
  return {
    schemaVersion: "analysis-vm.cas-010.v2",
    screenId: "CAS-010",
    caseId: string(vm.caseId) ?? string(response?.caseId) ?? "",
    screenState: string(vm.screenState) ?? string(response?.status) ?? "error",
    runs,
    filters:
      record(vm.filters) ??
      record(operation?.appliedFilters) ??
      record(response?.appliedFilters),
    suggestions,
    budget: record(vm.budget),
    visualizations,
    visualizationSetSha256:
      string(record(vm.visualizations)?.visualizationSetSha256) ?? "",
    viewModelSha256: string(vm.viewModelSha256) ?? "",
  };
}
