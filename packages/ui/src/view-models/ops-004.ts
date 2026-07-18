/**
 * Typed OPS-004 projection.
 *
 * `getBudgetOverview` is the historical operation name, but its v13 owner
 * projection is BusinessHealthV1.  The adapter deliberately keeps the
 * business evidence separate from the old budget envelope fields: a missing
 * budget id/version must not turn a valid health projection into an unknown,
 * and a partial health projection must never be presented as READY.
 */

export type Ops004ProjectionState = "READY" | "EMPTY" | "BLOCKED";

export type Ops004FunnelStage = {
  stage: string;
  state: string | null;
  organizationCount: number | null;
  unknownCount: number | null;
  earliestEnteredAt: string | null;
  latestEnteredAt: string | null;
  evidenceSetDigest: string | null;
  primaryIssueCode: string | null;
  ownerFunction: string | null;
};

export type Ops004MetricEvidence = {
  metricId: string;
  metricVersion: number | null;
  formulaDigest: string | null;
  policyDigest: string | null;
  inputSetDigest: string | null;
  status: string | null;
  reasonCode: string | null;
  resultKind: string | null;
  result: Record<string, unknown> | null;
  eligibleCount: number | null;
  pendingCount: number | null;
  unknownCount: number | null;
  unknownReasons: readonly Record<string, unknown>[];
  asOf: string | null;
  latestSourceAt: string | null;
  freshUntil: string | null;
  thresholdState: string | null;
  issueCode: string | null;
  breachAction: string | null;
};

export type Ops004ViewModel = {
  // Legacy budget envelope values remain available for deployments that still
  // return them, but they are not readiness gates for BusinessHealthV1.
  budgetId: string | null;
  budgetVersion: number | null;
  status: string;
  asOf: string | null;
  summary: string | null;
  providers: readonly string[];
  workloads: readonly string[];
  dailyLimit: string | null;
  monthlyLimit: string | null;
  dailyUsed: string | null;
  monthlyUsed: string | null;

  specificationVersion: string | null;
  metricCatalogDigest: string | null;
  funnel: readonly Ops004FunnelStage[];
  metrics: readonly Ops004MetricEvidence[];
  topIssue: Record<string, unknown> | null;
  unknownSourceCount: number | null;
  nextReviewAt: string | null;
  metricIdsComplete: boolean;
  funnelComplete: boolean;
  evidenceComplete: boolean;
  projectionState: Ops004ProjectionState;
};

const EXPECTED_FUNNEL = [
  "QUALIFIED",
  "CONFIGURED",
  "DATA_READY",
  "FIRST_PAID_VALUE",
  "ACTIVATED",
  "RETAINED",
  "AT_RISK",
  "CHURNED",
] as const;

const EXPECTED_METRICS = [
  "BM-ACQ-QUALIFIED-ORG-COUNT",
  "BM-ACQ-CHANNEL-MIX",
  "BM-FUNNEL-CONFIGURATION-RATE",
  "BM-FUNNEL-DATA-READY-RATE",
  "BM-VALUE-PAID-MVW",
  "BM-ACTIVATION-7D-RATE",
  "BM-ACTIVATION-TTFPV-P90",
  "BM-RETENTION-D29-56-RATE",
  "BM-RETENTION-AT-RISK-ORG-COUNT",
  "BM-RETENTION-CHURN-RATE",
  "BM-REVENUE-RECOGNIZED-KRW",
  "BM-BILLING-RECONCILIATION-COVERAGE",
  "BM-REVENUE-QUALIFIED-ORG-COUNT",
  "BM-VALUE-PAID-MVW-PER-ACTIVE-ORG",
  "BM-MARGIN-VARIABLE-GROSS-RATE",
  "BM-MARGIN-CONTRIBUTION-KRW",
  "BM-COST-PER-PAID-MVW-KRW",
  "BM-CAC-KRW",
  "BM-CAC-PAYBACK-MONTHS",
  "BM-SLA-AVAILABILITY-RATE",
  "BM-SUPPORT-HOURS-PER-ACTIVATED-ORG",
  "BM-TRUST-HARD-STOP-COUNT",
  "BM-FUNNEL-PILOT-TO-PAID-RATE",
  "BM-EXPANSION-ELIGIBILITY-RATE",
  "BM-RENEWAL-ELIGIBILITY-RATE",
] as const;

const EXPECTED_RESULT_KINDS: Record<string, string> = {
  "BM-ACQ-QUALIFIED-ORG-COUNT": "SCALAR",
  "BM-ACQ-CHANNEL-MIX": "SOURCE_BREAKDOWN",
  "BM-FUNNEL-CONFIGURATION-RATE": "BINOMIAL_RATE",
  "BM-FUNNEL-DATA-READY-RATE": "BINOMIAL_RATE",
  "BM-VALUE-PAID-MVW": "SCALAR",
  "BM-VALUE-PAID-MVW-PER-ACTIVE-ORG": "DETERMINISTIC_RATIO",
  "BM-ACTIVATION-7D-RATE": "BINOMIAL_RATE",
  "BM-ACTIVATION-TTFPV-P90": "TIME_TO_EVENT_P90",
  "BM-RETENTION-D29-56-RATE": "BINOMIAL_RATE",
  "BM-RETENTION-AT-RISK-ORG-COUNT": "SCALAR",
  "BM-RETENTION-CHURN-RATE": "BINOMIAL_RATE",
  "BM-FUNNEL-PILOT-TO-PAID-RATE": "BINOMIAL_RATE",
  "BM-REVENUE-QUALIFIED-ORG-COUNT": "SCALAR",
  "BM-EXPANSION-ELIGIBILITY-RATE": "BINOMIAL_RATE",
  "BM-RENEWAL-ELIGIBILITY-RATE": "BINOMIAL_RATE",
  "BM-REVENUE-RECOGNIZED-KRW": "SCALAR",
  "BM-BILLING-RECONCILIATION-COVERAGE": "DETERMINISTIC_RATIO",
  "BM-MARGIN-VARIABLE-GROSS-RATE": "DETERMINISTIC_RATIO",
  "BM-MARGIN-CONTRIBUTION-KRW": "SCALAR",
  "BM-COST-PER-PAID-MVW-KRW": "DETERMINISTIC_RATIO",
  "BM-CAC-KRW": "DETERMINISTIC_RATIO",
  "BM-CAC-PAYBACK-MONTHS": "DETERMINISTIC_RATIO",
  "BM-SLA-AVAILABILITY-RATE": "DETERMINISTIC_RATIO",
  "BM-SUPPORT-HOURS-PER-ACTIVATED-ORG": "DETERMINISTIC_RATIO",
  "BM-TRUST-HARD-STOP-COUNT": "SCALAR",
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;

const text = (value: unknown): string | null => {
  if (typeof value === "string" && value.trim()) return value;
  if (value === null || value === undefined) return null;
  return typeof value === "number" || typeof value === "boolean" ? String(value) : null;
};

const integer = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) && Number.isFinite(value) ? value : null;

const array = (value: unknown): readonly unknown[] => Array.isArray(value) ? value : [];

const arrayText = (value: unknown): string[] => array(value).flatMap((item) => {
  const row = record(item);
  if (row) return [text(row.name ?? row.provider ?? row.id ?? row.title ?? row.caseTitle) ?? "미명명 항목"];
  const scalar = text(item);
  return scalar ? [scalar] : [];
});

const sha256 = (value: string | null): boolean => value !== null && /^[a-f0-9]{64}$/i.test(value);

function parseFunnel(value: unknown): Ops004FunnelStage[] {
  return array(value).flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    return [{
      stage: text(row.stage) ?? "",
      state: text(row.state),
      organizationCount: integer(row.organizationCount),
      unknownCount: integer(row.unknownCount),
      earliestEnteredAt: text(row.earliestEnteredAt),
      latestEnteredAt: text(row.latestEnteredAt),
      evidenceSetDigest: text(row.evidenceSetDigest),
      primaryIssueCode: text(row.primaryIssueCode),
      ownerFunction: text(row.ownerFunction),
    } satisfies Ops004FunnelStage];
  });
}

function parseMetrics(value: unknown): Ops004MetricEvidence[] {
  return array(value).flatMap((item) => {
    const row = record(item);
    if (!row || !text(row.metricId)) return [];
    return [{
      metricId: text(row.metricId)!,
      metricVersion: integer(row.metricVersion),
      formulaDigest: text(row.formulaDigest),
      policyDigest: text(row.policyDigest),
      inputSetDigest: text(row.inputSetDigest),
      status: text(row.status),
      reasonCode: text(row.reasonCode),
      resultKind: text(row.resultKind),
      result: record(row.result),
      eligibleCount: integer(row.eligibleCount),
      pendingCount: integer(row.pendingCount),
      unknownCount: integer(row.unknownCount),
      unknownReasons: array(row.unknownReasons).flatMap((reason) => {
        const value = record(reason);
        return value ? [value] : [];
      }),
      asOf: text(row.asOf),
      latestSourceAt: text(row.latestSourceAt),
      freshUntil: text(row.freshUntil),
      thresholdState: text(row.thresholdState),
      issueCode: text(row.issueCode),
      breachAction: text(row.breachAction),
    } satisfies Ops004MetricEvidence];
  });
}

export function toOps004ViewModel(data: Record<string, unknown>): Ops004ViewModel {
  const response = record(data.getBudgetOverview) ?? data;
  const health = record(response.data) ?? response;
  const limits = record(health.limits) ?? {};
  const usage = record(health.usage) ?? {};
  const funnel = parseFunnel(health.funnel);
  const metrics = parseMetrics(health.metrics);
  const specificationVersion = text(health.specificationVersion ?? health.specification_version);
  const metricCatalogDigest = text(health.metricCatalogDigest ?? health.metric_catalog_digest);
  const budgetId = text(response.id ?? health.id);
  const budgetVersion = integer(response.version ?? health.version);
  const asOf = text(health.asOf ?? response.updatedAt ?? response.asOf ?? health.updatedAt);
  const summary = text(health.summary ?? response.summary);
  const funnelComplete = funnel.length === EXPECTED_FUNNEL.length
    && funnel.every((stage, index) => stage.stage === EXPECTED_FUNNEL[index]
      && stage.state !== null
      && stage.organizationCount !== null
      && stage.unknownCount !== null
      && sha256(stage.evidenceSetDigest)
      && stage.ownerFunction !== null);
  const metricIdsComplete = metrics.length === EXPECTED_METRICS.length
    && metrics.every((metric, index) => metric.metricId === EXPECTED_METRICS[index]);
  const evidenceComplete = metricIdsComplete
    && metrics.every((metric) => metric.metricVersion !== null
      && sha256(metric.formulaDigest)
      && sha256(metric.policyDigest)
      && sha256(metric.inputSetDigest)
      && metric.status !== null
      && metric.reasonCode !== null
      && metric.resultKind === EXPECTED_RESULT_KINDS[metric.metricId]
      && metric.result !== null
      && metric.result.kind === metric.resultKind
      && metric.eligibleCount !== null
      && metric.pendingCount !== null
      && metric.unknownCount !== null
      && metric.asOf !== null
      && metric.thresholdState !== null
      && metric.issueCode !== null
      && metric.breachAction !== null);
  const healthState = text(health.readinessState ?? response.status);
  const hasHealthProjection = specificationVersion !== null
    || metricCatalogDigest !== null
    || "readinessState" in health
    || "funnel" in health
    || "metrics" in health;
  const projectionState: Ops004ProjectionState = healthState === "READY" && specificationVersion !== null
    && metricCatalogDigest !== null && sha256(metricCatalogDigest) && text(health.nextReviewAt) !== null
    && asOf !== null && funnelComplete && evidenceComplete ? "READY" : hasHealthProjection ? "BLOCKED" : "EMPTY";
  return {
    budgetId,
    budgetVersion,
    status: healthState ?? "UNKNOWN",
    asOf,
    summary,
    providers: arrayText(health.providers),
    workloads: arrayText(health.workloads ?? health.topCases),
    dailyLimit: text(limits.daily ?? health.dailyLimit),
    monthlyLimit: text(limits.monthly ?? health.monthlyLimit),
    dailyUsed: text(usage.daily ?? health.dailyUsed),
    monthlyUsed: text(usage.monthly ?? health.monthlyUsed),
    specificationVersion,
    metricCatalogDigest,
    funnel,
    metrics,
    topIssue: record(health.topIssue),
    unknownSourceCount: integer(health.unknownSourceCount),
    nextReviewAt: text(health.nextReviewAt),
    metricIdsComplete,
    funnelComplete,
    evidenceComplete,
    projectionState,
  };
}
