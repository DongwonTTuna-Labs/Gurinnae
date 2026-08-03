export type Cas011Visualization = {
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
  readonly caseId: string;
  readonly runId: string;
  readonly screenState: string;
  readonly identity: Record<string, unknown>;
  readonly inputs: readonly Record<string, unknown>[];
  readonly output: { readonly summary: string } | null;
  readonly model: Record<string, unknown> | null;
  readonly safety: Record<string, unknown> | null;
  readonly cost: Record<string, unknown> | null;
  readonly citations: readonly Record<string, unknown>[];
  readonly decisions: readonly Record<string, unknown>[];
  readonly visualizations: readonly Cas011Visualization[];
  readonly visualizationSetSha256: string;
  readonly provenanceRows: readonly Cas011GraphRow[];
  readonly graphSha256: string;
  readonly accessibleRowsSha256: string;
  readonly viewModelSha256: string;
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;

const string = (value: unknown): string | null =>
  typeof value === "string" && value.length > 0 ? value : null;

const number = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? value : 0;

const records = (value: unknown): readonly Record<string, unknown>[] =>
  Array.isArray(value)
    ? value.flatMap((item) => {
        const row = record(item);
        return row ? [row] : [];
      })
    : [];

function visualization(value: unknown): Cas011Visualization | null {
  const item = record(value);
  const table = record(item?.tableAlternative);
  const id = string(item?.visualizationId);
  const title = string(item?.title);
  const formattedValue = string(item?.formattedValue);
  const narrative = string(item?.narrativeAlternative);
  const dataSha256 = string(table?.dataSha256);
  if (
    item?.kind !== "METRIC" ||
    !id ||
    !table ||
    !title ||
    !formattedValue ||
    !narrative ||
    !dataSha256
  )
    return null;
  return {
    visualizationId: id,
    title,
    value: number(item.value),
    formattedValue,
    narrativeAlternative: narrative,
    tableAlternative: {
      caption: string(table.caption) ?? title,
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
    const fromLabel = string(row.fromLabel);
    const relationLabel = string(row.relationLabel);
    const toLabel = string(row.toLabel);
    const factSha256 = string(row.factSha256);
    if (!fromLabel || !relationLabel || !toLabel || !factSha256) return [];
    return [
      {
        ordinal: number(row.ordinal),
        fromLabel,
        relationLabel,
        toLabel,
        sourceHref: string(row.sourceHref),
        factSha256,
      },
    ];
  });
}

/** Closed CAS-011 projection used by review-console sections and accessible graph tables. */
export function toCas011ViewModel(
  data: Record<string, unknown>,
): Cas011ViewModel | null {
  const response = record(data.getAgentRun) ?? record(data);
  const envelope = record(response?.data) ?? response;
  const vm = record(envelope?.analysisVm) ?? record(response?.analysisVm);
  if (
    vm?.schemaVersion !== "analysis-vm.cas-011.v2" ||
    vm.screenId !== "CAS-011"
  ) {
    const inputs = Array.isArray(envelope?.evidenceScopeIds)
      ? envelope.evidenceScopeIds.flatMap((value) =>
          typeof value === "string" ? [{ sourceId: value }] : [],
        )
      : [];
    const citations = Array.isArray(envelope?.citations)
      ? envelope.citations.flatMap((value) =>
          typeof value === "string" ? [{ sourceId: value }] : [],
        )
      : [];
    const output = string(envelope?.output);
    return {
      schemaVersion: "analysis-vm.cas-011.v2",
      screenId: "CAS-011",
      caseId: string(envelope?.caseId) ?? "",
      runId: string(envelope?.id) ?? "",
      screenState: string(envelope?.status) ?? "unknown",
      identity: {
        status: envelope?.status,
        objective: envelope?.objective,
        agentType: envelope?.agentType,
      },
      inputs,
      model:
        envelope?.provider || envelope?.model
          ? { provider: envelope.provider, model: envelope.model }
          : null,
      output: output ? { summary: output } : null,
      safety: {
        unknowns: Array.isArray(envelope?.unknowns) ? envelope.unknowns : [],
        state: "UNKNOWN",
        unknownReason: "AUTHORITY_AGENT_RUN_HAS_NO_SAFETY_PROJECTION",
      },
      cost: record(envelope?.cost),
      citations,
      decisions: [],
      visualizations: [],
      visualizationSetSha256: "",
      provenanceRows: [],
      graphSha256: "",
      accessibleRowsSha256: "",
      viewModelSha256: "",
    };
  }
  const visuals = record(vm.visualizations);
  const visualItems = visuals?.visualizations;
  return {
    schemaVersion: "analysis-vm.cas-011.v2",
    screenId: "CAS-011",
    caseId: string(vm.caseId) ?? string(envelope?.caseId) ?? "",
    runId: string(vm.runId) ?? string(envelope?.id) ?? "",
    screenState: string(vm.screenState) ?? string(envelope?.status) ?? "error",
    identity: record(vm.identity) ?? {
      status: envelope?.status,
      objective: envelope?.objective,
    },
    inputs: records(vm.inputs).length
      ? records(vm.inputs)
      : records(envelope?.sourceUses),
    output: (() => {
      const value = record(vm.output) ?? record(envelope?.output);
      const summary = string(value?.summary ?? value?.text ?? value?.content);
      return summary ? { summary } : null;
    })(),
    model: record(vm.model) ?? record(envelope?.model),
    safety: record(vm.safety) ?? record(envelope?.safety),
    cost: record(vm.cost) ?? record(envelope?.cost),
    citations: records(vm.citations).length
      ? records(vm.citations)
      : records(envelope?.citations),
    decisions: records(vm.decisions).length
      ? records(vm.decisions)
      : records(envelope?.suggestions),
    visualizations: Array.isArray(visualItems)
      ? visualItems
          .map(visualization)
          .filter((item): item is Cas011Visualization => item !== null)
      : [],
    visualizationSetSha256: string(visuals?.visualizationSetSha256) ?? "",
    provenanceRows: graphRows(record(vm.provenanceGraph)?.accessibleRows),
    graphSha256: string(record(vm.provenanceGraph)?.graphSha256) ?? "",
    accessibleRowsSha256:
      string(record(vm.provenanceGraph)?.accessibleRowsSha256) ?? "",
    viewModelSha256: string(vm.viewModelSha256) ?? "",
  };
}
