import type { ProjectionField, SafeProjectionValue } from "./screen-projection";
import type { SpecializedProjection } from "./screen-projection-specialized-types";
import { toOps004ViewModel } from "./view-models/ops-004";

const scalar = (value: unknown): SafeProjectionValue | null =>
  typeof value === "string" ||
  typeof value === "number" ||
  typeof value === "boolean"
    ? value
    : null;
const field = (
  name: string,
  label: string,
  value: SafeProjectionValue | null,
  source: string,
): ProjectionField => ({ name, label, value, known: value !== null, source });

export function ops004Fields(
  sectionId: string,
  data: Record<string, unknown>,
): SpecializedProjection | null {
  const vm = toOps004ViewModel(data);
  const common = [
    field("status", "예산 상태", vm.status, "BudgetOverviewResponse.status"),
    field("updated_at", "갱신 시각", vm.updatedAt, "BudgetOverview.updatedAt"),
  ];
  const latest = vm.dailySeries.at(-1);
  const alert = vm.alerts.at(-1);
  const change = vm.changes.at(-1);
  const fieldsBySection: Record<string, ProjectionField[]> = {
    envelope: [
      field(
        "budget_id",
        "예산 식별자",
        vm.budgetId,
        "BudgetOverviewResponse.id",
      ),
      field(
        "budget_version",
        "예산 버전",
        vm.budgetVersion,
        "BudgetOverviewResponse.version",
      ),
      ...common,
      field(
        "currency",
        "통화",
        vm.summary?.currency ?? null,
        "BudgetOverview.summary.currency",
      ),
    ],
    spend: [
      ...common,
      field(
        "daily_used",
        "오늘 사용량",
        vm.dailyUsed,
        "BudgetOverview.summary.dailyUsed",
      ),
      field(
        "monthly_used",
        "이번 달 사용량",
        vm.monthlyUsed,
        "BudgetOverview.summary.monthlyUsed",
      ),
      field(
        "providers",
        "공급자",
        vm.providers.join(" · ") || null,
        "BudgetOverview.providers",
      ),
      field(
        "top_cases",
        "상위 케이스",
        vm.workloads.join(" · ") || null,
        "BudgetOverview.topCases",
      ),
    ],
    forecast: [
      ...common,
      field(
        "series_points",
        "일별 시계열 수",
        vm.dailySeries.length,
        "BudgetOverview.dailySeries",
      ),
      field(
        "forecast_state",
        "예측 상태",
        vm.forecast.state,
        "BudgetOverview.forecast.state",
      ),
      field(
        "forecast_confidence",
        "예측 신뢰도",
        vm.forecast.confidence,
        "BudgetOverview.forecast.confidence",
      ),
      field(
        "forecast_assumption",
        "예측 가정",
        vm.forecast.assumption ?? (vm.forecast.assumptions.join(" · ") || null),
        "BudgetOverview.forecast.assumption",
      ),
      field(
        "forecast_unknown_reason",
        "예측을 모르는 이유",
        vm.forecast.unknownReason,
        "BudgetOverview.forecast.unknownReason",
      ),
      field(
        "latest_point",
        "최근 일별 비용",
        latest
          ? `${latest.amount ?? "확인되지 않음"} ${latest.currency ?? vm.summary?.currency ?? ""}`.trim()
          : null,
        "BudgetOverview.dailySeries[-1]",
      ),
    ],
    limits: [
      ...common,
      field(
        "daily_limit",
        "일일 한도",
        vm.dailyLimit,
        "BudgetOverview.summary.dailyLimit",
      ),
      field(
        "monthly_limit",
        "월간 한도",
        vm.monthlyLimit,
        "BudgetOverview.summary.monthlyLimit",
      ),
      field(
        "soft_limit",
        "소프트 한도",
        scalar(vm.limits?.softLimit),
        "BudgetOverview.limits.softLimit",
      ),
      field(
        "hard_limit",
        "하드 한도",
        scalar(vm.limits?.hardLimit),
        "BudgetOverview.limits.hardLimit",
      ),
      field(
        "fallback_action",
        "한도 초과 시 중단",
        scalar(vm.limits?.fallbackAction),
        "BudgetOverview.limits.fallbackAction",
      ),
      field(
        "limit_owner",
        "한도 변경 담당자",
        scalar(vm.limits?.updatedBy),
        "BudgetOverview.limits.updatedBy",
      ),
      field(
        "limit_version",
        "한도 버전",
        scalar(vm.limits?.version),
        "BudgetOverview.limits.version",
      ),
    ],
    alerts: [
      ...common,
      field(
        "limit_state",
        "한도 판정",
        vm.summary?.status ?? null,
        "BudgetOverview.summary.status",
      ),
      field(
        "alert_count",
        "경고 건수",
        vm.alerts.length,
        "BudgetOverview.alerts",
      ),
      field(
        "alert_threshold",
        "경고 임계값",
        scalar(alert?.threshold ?? vm.summary?.dailyLimit),
        "BudgetOverview.alerts[-1].threshold",
      ),
      field(
        "alert_reason",
        "경고 사유",
        scalar(alert?.reason ?? alert?.kind),
        "BudgetOverview.alerts[-1].reason",
      ),
      field(
        "alert_details",
        "경고 내용",
        vm.alerts.length
          ? (scalar(alert?.reason ?? alert?.kind) ?? "확인됨")
          : null,
        "BudgetOverview.alerts[-1].reason",
      ),
    ],
    changes: [
      field(
        "updated_at",
        "마지막 변경 시각",
        vm.updatedAt,
        "BudgetOverview.updatedAt",
      ),
      field(
        "budget_version",
        "예산 버전",
        vm.budgetVersion,
        "BudgetOverviewResponse.version",
      ),
      field(
        "change_owner",
        "변경 승인자",
        scalar(change?.approver ?? change?.updatedBy),
        "BudgetOverview.changes[-1].approver",
      ),
      field(
        "change_reason",
        "변경 사유",
        scalar(change?.reason),
        "BudgetOverview.changes[-1].reason",
      ),
    ],
  };
  const fields = fieldsBySection[sectionId];
  return fields ? { fields, blocked: vm.projectionState !== "READY" } : null;
}
