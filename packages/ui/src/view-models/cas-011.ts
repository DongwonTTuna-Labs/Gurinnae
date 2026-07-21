import type { Cas010Metric } from "./cas-010";

export type Cas011GraphRow = {
  readonly ordinal: number;
  readonly fromLabel: string;
  readonly relationLabel: string;
  readonly toLabel: string;
  readonly sourceHref: string | null;
  readonly factSha256: string;
};

export type Cas011ViewModel = {
  readonly schemaVersion: "analysis-vm.cas-011.v2";
  readonly screenId: "CAS-011";
  readonly caseId: string | null;
  readonly runId: string | null;
  readonly screenState: string | null;
  readonly identity: Record<string, unknown> | null;
  readonly inputs: readonly Record<string, unknown>[];
  readonly model: Record<string, unknown> | null;
  readonly output: { readonly summary: string } | null;
  readonly citations: readonly Record<string, unknown>[];
  readonly safety: Record<string, unknown> | null;
  readonly decisions: readonly Record<string, unknown>[];
  readonly cost: Record<string, unknown> | null;
  readonly visualizations: readonly Cas010Metric[];
  readonly visualizationSetSha256: string | null;
  readonly provenanceRows: readonly Cas011GraphRow[];
  readonly graphSha256: string | null;
  readonly accessibleRowsSha256: string | null;
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

function graphRows(value: unknown): readonly Cas011GraphRow[] {
  return records(value).flatMap((row) => {
    const fromLabel = text(row.fromLabel);
    const relationLabel = text(row.relationLabel);
    const toLabel = text(row.toLabel);
    const factSha256 = text(row.factSha256);
    if (!fromLabel || !relationLabel || !toLabel || !factSha256) return [];
    if (
      typeof row.ordinal !== "number" ||
      !Number.isInteger(row.ordinal) ||
      row.ordinal < 0
    )
      return [];
    return [
      {
        ordinal: row.ordinal,
        fromLabel,
        relationLabel,
        toLabel,
        sourceHref: text(row.sourceHref),
        factSha256,
      },
    ];
  });
}

/** Unwraps the typed analysis projection or the closed v13 AgentRun DTO. */
export function toCas011ViewModel(
  data: Record<string, unknown>,
): Cas011ViewModel | null {
  const operation = record(data.getAgentRun) ?? record(data);
  const envelope = record(operation?.data) ?? operation;
  const vm = record(envelope?.analysisVm) ?? record(operation?.analysisVm);
  if (
    vm?.schemaVersion !== "analysis-vm.cas-011.v2" ||
    vm.screenId !== "CAS-011"
  ) {
    const evidenceScopeIds = Array.isArray(envelope?.evidenceScopeIds)
      ? envelope.evidenceScopeIds.flatMap((value) =>
          typeof value === "string" ? [{ sourceId: value }] : [],
        )
      : [];
    const citations = Array.isArray(envelope?.citations)
      ? envelope.citations.flatMap((value) =>
          typeof value === "string" ? [{ sourceId: value }] : [],
        )
      : [];
    const outputText = text(envelope?.output);
    return {
      schemaVersion: "analysis-vm.cas-011.v2",
      screenId: "CAS-011",
      caseId: text(envelope?.caseId),
      runId: text(envelope?.id) ?? text(operation?.id),
      screenState: text(envelope?.status) ?? "unknown",
      identity: {
        status: envelope?.status,
        objective: envelope?.objective,
        agentType: envelope?.agentType,
      },
      inputs: evidenceScopeIds,
      model:
        envelope?.provider || envelope?.model
          ? { provider: envelope.provider, model: envelope.model }
          : null,
      output: outputText ? { summary: outputText } : null,
      citations,
      safety: {
        unknowns: Array.isArray(envelope?.unknowns) ? envelope.unknowns : [],
        state: "UNKNOWN",
        unknownReason: "AUTHORITY_AGENT_RUN_HAS_NO_SAFETY_PROJECTION",
      },
      decisions: [],
      cost: record(envelope?.cost),
      visualizations: [],
      visualizationSetSha256: null,
      provenanceRows: [],
      graphSha256: null,
      accessibleRowsSha256: null,
      viewModelSha256: null,
    };
  }
  const visualizationSet = record(vm.visualizations);
  const graph = record(vm.provenanceGraph);
  return {
    schemaVersion: "analysis-vm.cas-011.v2",
    screenId: "CAS-011",
    caseId: text(vm.caseId) ?? text(envelope?.caseId),
    runId: text(vm.runId) ?? text(envelope?.id),
    screenState: text(vm.screenState) ?? text(envelope?.status),
    identity: record(vm.identity),
    inputs: records(vm.inputs),
    model: record(vm.model),
    output: (() => {
      const value = record(vm.output);
      const summary = text(
        value?.summary ??
          value?.answerFirstSummary ??
          value?.text ??
          value?.content,
      );
      return summary ? { summary } : null;
    })(),
    citations: records(vm.citations),
    safety: record(vm.safety),
    decisions: records(vm.decisions),
    cost: record(vm.cost),
    visualizations: Array.isArray(visualizationSet?.visualizations)
      ? visualizationSet.visualizations
          .map(metric)
          .filter((item): item is Cas010Metric => item !== null)
      : [],
    visualizationSetSha256: text(visualizationSet?.visualizationSetSha256),
    provenanceRows: graphRows(graph?.accessibleRows),
    graphSha256: text(graph?.graphSha256),
    accessibleRowsSha256: text(graph?.accessibleRowsSha256),
    viewModelSha256: text(vm.viewModelSha256),
  };
}
