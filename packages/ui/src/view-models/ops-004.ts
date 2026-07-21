/** Typed adapter for the authority BudgetOverviewResponse contract. */
export type Ops004ProjectionState = "READY" | "EMPTY" | "BLOCKED";
export type Ops004BudgetSummary = {
  currency: string | null;
  dailyLimit: string | null;
  dailyUsed: string | null;
  monthlyLimit: string | null;
  monthlyUsed: string | null;
  status: string | null;
  forecastAssumption?: string | null;
  softLimit?: string | null;
  hardLimit?: string | null;
  fallbackAction?: string | null;
  alertThreshold?: string | null;
  lastChangedBy?: string | null;
  lastChangeReason?: string | null;
  unknownReason?: string | null;
  forecastConfidence?: string | null;
  asOf?: string | null;
  reservationSummary?: Record<string, unknown> | null;
};
export type Ops004CostPoint = {
  at: string | null;
  amount: string | null;
  currency: string | null;
};
export type Ops004CaseCost = {
  caseId: string | null;
  caseTitle: string | null;
  amount: string | null;
  currency: string | null;
  runCount: number | null;
};
export type Ops004ViewModel = {
  budgetId: string | null;
  budgetVersion: number | null;
  status: string;
  asOf: string | null;
  updatedAt: string | null;
  summary: Ops004BudgetSummary | null;
  providers: readonly string[];
  workloads: readonly string[];
  dailySeries: readonly Ops004CostPoint[];
  topCases: readonly Ops004CaseCost[];
  dailyLimit: string | null;
  monthlyLimit: string | null;
  dailyUsed: string | null;
  monthlyUsed: string | null;
  forecast: {
    state: string | null;
    unknownReason: string | null;
    confidence: string | null;
    assumption: string | null;
    assumptions: readonly string[];
  };
  limits: Record<string, unknown> | null;
  alerts: readonly Record<string, unknown>[];
  changes: readonly Record<string, unknown>[];
  businessHealth: Record<string, unknown> | null;
  projectionState: Ops004ProjectionState;
};
const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
const text = (value: unknown): string | null =>
  typeof value === "string" && value.trim()
    ? value
    : typeof value === "number" || typeof value === "boolean"
      ? String(value)
      : null;
const integer = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) && Number.isFinite(value)
    ? value
    : null;
const array = (value: unknown): readonly unknown[] =>
  Array.isArray(value) ? value : [];
const arrayText = (value: unknown): string[] =>
  array(value).flatMap((item) => {
    const row = record(item);
    const label = row
      ? text(row.name ?? row.provider ?? row.id ?? row.title ?? row.caseTitle)
      : text(item);
    return label ? [label] : [];
  });
function parseSummary(value: unknown): Ops004BudgetSummary | null {
  const row = record(value);
  return row
    ? {
        currency: text(row.currency),
        dailyLimit: text(row.dailyLimit),
        dailyUsed: text(row.dailyUsed),
        monthlyLimit: text(row.monthlyLimit),
        monthlyUsed: text(row.monthlyUsed),
        status: text(row.status),
        forecastAssumption: text(row.forecastAssumption),
        softLimit: text(row.softLimit),
        hardLimit: text(row.hardLimit),
        fallbackAction: text(row.fallbackAction),
        alertThreshold: text(row.alertThreshold),
        lastChangedBy: text(row.lastChangedBy),
        lastChangeReason: text(row.lastChangeReason),
        unknownReason: text(row.unknownReason),
        forecastConfidence: text(row.forecastConfidence),
        asOf: text(row.asOf),
        reservationSummary: record(row.reservationSummary),
      }
    : null;
}
function parseSeries(value: unknown): Ops004CostPoint[] {
  return array(value).flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    const amount = record(row.amount);
    return [
      {
        at: text(row.at),
        amount: text(amount?.amount ?? row.amount),
        currency: text(amount?.currency),
      },
    ];
  });
}
function parseCases(value: unknown): Ops004CaseCost[] {
  return array(value).flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    const amount = record(row.amount);
    return [
      {
        caseId: text(row.caseId),
        caseTitle: text(row.caseTitle),
        amount: text(amount?.amount ?? row.amount),
        currency: text(amount?.currency),
        runCount: integer(row.runCount),
      },
    ];
  });
}
export function toOps004ViewModel(
  data: Record<string, unknown>,
): Ops004ViewModel {
  const response = record(data.getBudgetOverview) ?? data;
  const body = record(response.data) ?? response;
  const summary = parseSummary(body.summary);
  const providers = arrayText(body.providers);
  const dailySeries = parseSeries(body.dailySeries);
  const topCases = parseCases(body.topCases);
  const updatedAt = text(body.updatedAt ?? response.updatedAt);
  const forecast: Record<string, unknown> | null =
    record(body.forecast) ??
    (summary
      ? {
          state: summary.status,
          unknownReason: summary.unknownReason,
          forecastConfidence: summary.forecastConfidence,
          forecastAssumption: summary.forecastAssumption,
        }
      : null);
  const limits =
    record(body.limits) ??
    (summary
      ? {
          softLimit: summary.softLimit,
          hardLimit: summary.hardLimit,
          alertThreshold: summary.alertThreshold,
          fallbackAction: summary.fallbackAction,
        }
      : null);
  const alerts = array(body.alerts).flatMap((item) => {
    const row = record(item);
    return row ? [row] : [];
  });
  const changes = array(body.changes).flatMap((item) => {
    const row = record(item);
    return row ? [row] : [];
  });
  const businessHealth = record(body.businessHealth);
  const complete =
    summary !== null &&
    summary.currency !== null &&
    summary.dailyLimit !== null &&
    summary.dailyUsed !== null &&
    summary.monthlyLimit !== null &&
    summary.monthlyUsed !== null &&
    summary.status !== null &&
    updatedAt !== null &&
    providers.length > 0 &&
    dailySeries.length > 0 &&
    dailySeries.every(
      (point) =>
        point.at !== null && point.amount !== null && point.currency !== null,
    ) &&
    topCases.length > 0 &&
    topCases.every(
      (item) =>
        item.caseId !== null &&
        item.caseTitle !== null &&
        item.amount !== null &&
        item.currency !== null &&
        item.runCount !== null,
    );
  const projectionState: Ops004ProjectionState =
    complete && summary.status !== "UNKNOWN"
      ? "READY"
      : summary
        ? "BLOCKED"
        : "EMPTY";
  return {
    budgetId: text(response.id),
    budgetVersion: integer(response.version),
    status: text(response.status ?? summary?.status) ?? "UNKNOWN",
    asOf: updatedAt,
    updatedAt,
    summary,
    providers,
    workloads: topCases.flatMap((item) =>
      item.caseTitle ? [item.caseTitle] : [],
    ),
    dailySeries,
    topCases,
    dailyLimit: summary?.dailyLimit ?? null,
    monthlyLimit: summary?.monthlyLimit ?? null,
    dailyUsed: summary?.dailyUsed ?? null,
    monthlyUsed: summary?.monthlyUsed ?? null,
    forecast: {
      state: text(forecast?.state),
      unknownReason:
        text(forecast?.unknownReason) ??
        (forecast ? null : "FORECAST_OWNER_FACT_MISSING"),
      confidence: text(forecast?.confidence ?? forecast?.forecastConfidence),
      assumption: text(forecast?.assumption ?? forecast?.forecastAssumption),
      assumptions: arrayText(forecast?.assumptions),
    },
    limits,
    alerts,
    changes,
    businessHealth,
    projectionState,
  };
}
