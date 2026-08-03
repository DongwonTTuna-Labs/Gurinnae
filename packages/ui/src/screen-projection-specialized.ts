import type { ProjectionField, SafeProjectionValue } from "./screen-projection";
import { ops004Fields } from "./screen-projection-ops";
import {
  nestedRows,
  rowFields,
  scalar,
  summarize,
} from "./screen-projection-specialized-helpers";
import { responseSpecializedFields } from "./screen-projection-specialized-response";
import type { SpecializedProjection } from "./screen-projection-specialized-types";
import { toCas010ViewModel } from "./view-models/cas-010";
import { toCas011ViewModel } from "./view-models/cas-011";
import { toInt002ViewModel } from "./view-models/int-002";

function factsToFields(
  facts: readonly { label: string; value: string; href?: string }[],
  source: string,
): ProjectionField[] {
  return facts.map((fact) => ({
    name: fact.label,
    label: fact.label,
    value: fact.value,
    known: true,
    source: fact.href ? `${source}.${fact.href}` : source,
  }));
}

function field(
  name: string,
  label: string,
  value: SafeProjectionValue | null,
  source: string,
): ProjectionField {
  return {
    name,
    label,
    value,
    known: value !== null && value !== undefined,
    source,
  };
}

export function specializedFields(
  screenId: string,
  sectionId: string,
  data: Record<string, unknown>,
): SpecializedProjection | null {
  const responseProjection = responseSpecializedFields(
    screenId,
    sectionId,
    data,
  );
  if (responseProjection && screenId !== "CAS-010" && screenId !== "CAS-011")
    return responseProjection;
  if (screenId === "INT-002") {
    const vm = toInt002ViewModel(data);
    const projection =
      sectionId === "views"
        ? vm.viewsObject
        : sectionId === "tasks"
          ? vm.tasksAnswer
          : sectionId === "handoff"
            ? vm.handoffEvidence
            : null;
    if (projection)
      return {
        fields: factsToFields(projection.facts, projection.provenance),
        blocked: projection.status === "BLOCKED",
      };
  }
  if (screenId === "CAS-010") {
    const vm = toCas010ViewModel(data);
    if (!vm) return null;
    const common = [
      field("screen_state", "상태", vm.screenState, "analysisVm.screenState"),
      field("case_id", "케이스", vm.caseId, "analysisVm.caseId"),
      field(
        "view_model_digest",
        "화면 모델 무결성",
        vm.viewModelSha256,
        "analysisVm.viewModelSha256",
      ),
    ];
    const visualFields = vm.visualizations.flatMap((visual) => [
      field(
        `visualization_${visual.visualizationId}_value`,
        `${visual.title} · 값`,
        visual.formattedValue,
        `analysisVm.visualizations[${visual.visualizationId}].formattedValue`,
      ),
      field(
        `visualization_${visual.visualizationId}_narrative`,
        `${visual.title} · 해석`,
        visual.narrativeAlternative,
        `analysisVm.visualizations[${visual.visualizationId}].narrativeAlternative`,
      ),
      field(
        `visualization_${visual.visualizationId}_table_digest`,
        `${visual.title} · 표 무결성`,
        visual.tableAlternative.dataSha256,
        `analysisVm.visualizations[${visual.visualizationId}].tableAlternative.dataSha256`,
      ),
    ]);
    const budgetValues =
      vm.budget &&
      typeof vm.budget.values === "object" &&
      vm.budget.values !== null &&
      !Array.isArray(vm.budget.values)
        ? (vm.budget.values as Record<string, unknown>)
        : null;
    const fieldsBySection: Record<string, ProjectionField[]> = {
      runs: [
        ...common,
        field("runs", "실행", vm.runs.length, "analysisVm.runs"),
        ...rowFields(
          "run",
          vm.runs,
          [
            ["runId", "실행 식별자"],
            ["agentTypeLabel", "에이전트 유형"],
            ["objective", "목적"],
            ["statusLabel", "상태"],
            ["costMicrosKrw", "확정 비용"],
            ["href", "상세 보기"],
          ],
          "analysisVm.runs",
        ),
        field("run_count", "실행 건수", vm.runs.length, "analysisVm.runs"),
        ...visualFields,
      ],
      filters: [
        field(
          "filters",
          "적용 필터",
          summarize(vm.filters),
          "analysisVm.filters",
        ),
        field(
          "filter_agent_types",
          "에이전트 유형 필터",
          scalar(vm.filters?.agentTypes),
          "analysisVm.filters.agentTypes",
        ),
        field(
          "filter_statuses",
          "상태 필터",
          scalar(vm.filters?.statuses),
          "analysisVm.filters.statuses",
        ),
        field(
          "filter_proposal_states",
          "제안 상태 필터",
          scalar(vm.filters?.proposalStates),
          "analysisVm.filters.proposalStates",
        ),
        field(
          "filter_sort",
          "정렬",
          scalar(vm.filters?.sort),
          "analysisVm.filters.sort",
        ),
      ],
      suggestions: [
        field(
          "suggestions",
          "제안",
          vm.suggestions.length,
          "analysisVm.suggestions",
        ),
        ...rowFields(
          "suggestion",
          vm.suggestions,
          [
            ["id", "제안 식별자"],
            ["type", "제안 유형"],
            ["status", "상태"],
            ["decisionReason", "결정 사유"],
          ],
          "analysisVm.suggestions",
        ),
        field(
          "suggestion_count",
          "제안 건수",
          vm.suggestions.length,
          "analysisVm.suggestions",
        ),
      ],
      budget: [
        field("budget", "예산 상태", summarize(vm.budget), "analysisVm.budget"),
        field(
          "budget_state",
          "예산 판정",
          scalar(vm.budget?.state),
          "analysisVm.budget.state",
        ),
        field(
          "budget_limit",
          "예산 한도(마이크로 원화)",
          scalar(budgetValues?.limitMicrosKrw),
          "analysisVm.budget.values.limitMicrosKrw",
        ),
        field(
          "budget_reserved",
          "예약 비용(마이크로 원화)",
          scalar(budgetValues?.reservedMicrosKrw),
          "analysisVm.budget.values.reservedMicrosKrw",
        ),
        field(
          "budget_settled",
          "확정 비용(마이크로 원화)",
          scalar(budgetValues?.settledMicrosKrw),
          "analysisVm.budget.values.settledMicrosKrw",
        ),
        field(
          "budget_remaining",
          "잔여 비용(마이크로 원화)",
          scalar(budgetValues?.remainingMicrosKrw),
          "analysisVm.budget.values.remainingMicrosKrw",
        ),
        field(
          "budget_unknown_reason",
          "비용 미확인 사유",
          scalar(vm.budget?.unknownReason),
          "analysisVm.budget.unknownReason",
        ),
      ],
    };
    const fields = fieldsBySection[sectionId];
    return fields
      ? {
          fields,
          blocked:
            vm.budget?.state === "BLOCKED" &&
            scalar(vm.budget?.unknownReason) !== null,
          analysis: { visualizations: vm.visualizations, provenanceRows: [] },
        }
      : null;
  }
  if (screenId === "CAS-011") {
    const vm = toCas011ViewModel(data);
    if (!vm) return null;
    const common = [
      field("screen_state", "상태", vm.screenState, "analysisVm.screenState"),
      field("case_id", "케이스", vm.caseId, "analysisVm.caseId"),
      field("run_id", "실행", vm.runId, "analysisVm.runId"),
      field(
        "view_model_digest",
        "화면 모델 무결성",
        vm.viewModelSha256,
        "analysisVm.viewModelSha256",
      ),
    ];
    const graphFields = [
      field(
        "provenance_rows",
        "접근 가능한 근거 행",
        vm.provenanceRows.length || null,
        "analysisVm.provenanceGraph.accessibleRows",
      ),
      field(
        "graph_digest",
        "근거 그래프 무결성",
        vm.graphSha256,
        "analysisVm.provenanceGraph.graphSha256",
      ),
      field(
        "accessible_rows_digest",
        "근거 행 무결성",
        vm.accessibleRowsSha256,
        "analysisVm.provenanceGraph.accessibleRowsSha256",
      ),
    ];
    const visualFields = vm.visualizations.flatMap((visual) => [
      field(
        `visualization_${visual.visualizationId}_value`,
        `${visual.title} · 값`,
        visual.formattedValue,
        `analysisVm.visualizations[${visual.visualizationId}].formattedValue`,
      ),
      field(
        `visualization_${visual.visualizationId}_narrative`,
        `${visual.title} · 해석`,
        visual.narrativeAlternative,
        `analysisVm.visualizations[${visual.visualizationId}].narrativeAlternative`,
      ),
      field(
        `visualization_${visual.visualizationId}_table_digest`,
        `${visual.title} · 표 무결성`,
        visual.tableAlternative.dataSha256,
        `analysisVm.visualizations[${visual.visualizationId}].tableAlternative.dataSha256`,
      ),
    ]);
    const fieldsBySection: Record<string, ProjectionField[]> = {
      identity: [
        ...common,
        field(
          "identity",
          "실행 식별 정보",
          summarize(vm.identity),
          "analysisVm.identity",
        ),
        ...rowFields(
          "identity",
          vm.identity ? [vm.identity] : [],
          [
            ["agentTypeLabel", "에이전트 유형"],
            ["objective", "목적"],
            ["statusLabel", "상태"],
            ["controlState", "제어 상태"],
            ["snapshotSha256", "입력 스냅샷"],
          ],
          "analysisVm.identity",
        ),
      ],
      inputs: [
        field("inputs", "입력 출처", vm.inputs.length, "analysisVm.inputs"),
        ...rowFields(
          "input",
          vm.inputs,
          [
            ["sourceUseId", "출처 사용 식별자"],
            ["humanLabel", "출처"],
            ["revisionLabel", "개정본"],
            ["contentSha256", "콘텐츠 무결성"],
            ["rightsState", "권리 상태"],
            ["locatorLabel", "위치"],
            ["href", "출처 보기"],
          ],
          "analysisVm.inputs",
        ),
        ...graphFields,
      ],
      model: [
        field("model", "모델 실행", summarize(vm.model), "analysisVm.model"),
        ...rowFields(
          "model",
          vm.model ? [vm.model] : [],
          [
            ["providerLabel", "제공자"],
            ["modelLabel", "모델"],
            ["promptVersion", "프롬프트 버전"],
            ["promptSha256", "프롬프트 무결성"],
            ["outputSchemaVersion", "출력 스키마"],
            ["receiptState", "영수증 상태"],
          ],
          "analysisVm.model",
        ),
      ],
      output: [
        field("output", "출력", summarize(vm.output), "analysisVm.output"),
        ...rowFields(
          "output",
          vm.output ? [vm.output] : [],
          [
            ["status", "출력 상태"],
            ["answerFirstSummary", "요약"],
          ],
          "analysisVm.output",
        ),
        ...nestedRows(
          "output",
          vm.output,
          "hypotheses",
          "가설",
          "analysisVm.output",
        ),
        ...nestedRows(
          "output",
          vm.output,
          "counterEvidence",
          "반대 근거",
          "analysisVm.output",
        ),
        ...nestedRows(
          "output",
          vm.output,
          "unknowns",
          "미확인",
          "analysisVm.output",
        ),
        ...nestedRows(
          "output",
          vm.output,
          "investigationsPerformed",
          "수행 조사",
          "analysisVm.output",
        ),
        ...nestedRows(
          "output",
          vm.output,
          "nextActions",
          "다음 행동",
          "analysisVm.output",
        ),
        ...visualFields,
      ],
      citations: [
        ...rowFields(
          "citation",
          vm.citations,
          [
            ["citationId", "인용 식별자"],
            ["sourceLabel", "출처"],
            ["locatorLabel", "위치"],
            ["supports", "뒷받침 내용"],
            ["citationSha256", "인용 무결성"],
            ["href", "인용 보기"],
          ],
          "analysisVm.citations",
        ),
        ...graphFields,
      ],
      safety: [
        ...rowFields(
          "safety",
          vm.safety ? [vm.safety] : [],
          [
            ["promptInjectionState", "프롬프트 주입"],
            ["personalDataState", "개인정보"],
            ["rightsState", "권리"],
            ["classificationState", "분류"],
            ["state", "종합 판정"],
            ["reason", "판정 사유"],
          ],
          "analysisVm.safety",
        ),
      ],
      decisions: [
        ...rowFields(
          "decision",
          vm.decisions,
          [
            ["proposalId", "제안 식별자"],
            ["proposalType", "제안 유형"],
            ["summary", "내용"],
            ["status", "상태"],
            ["decisionReason", "결정 사유"],
            ["decidedByLabel", "결정자"],
            ["decidedAt", "결정 시각"],
          ],
          "analysisVm.decisions",
        ),
        field(
          "decision_count",
          "사람 결정 건수",
          vm.decisions.length,
          "analysisVm.decisions",
        ),
      ],
      cost: [
        field("cost", "비용 상태", summarize(vm.cost), "analysisVm.cost"),
        field(
          "cost_state",
          "비용 원장 상태",
          scalar(vm.cost?.state),
          "analysisVm.cost.state",
        ),
        field(
          "cost_limit",
          "비용 한도(마이크로 원화)",
          scalar(vm.cost?.limitMicrosKrw),
          "analysisVm.cost.limitMicrosKrw",
        ),
        field(
          "cost_settled",
          "확정 비용(마이크로 원화)",
          scalar(vm.cost?.settledMicrosKrw),
          "analysisVm.cost.settledMicrosKrw",
        ),
        field(
          "cost_remaining",
          "잔여 비용(마이크로 원화)",
          scalar(vm.cost?.remainingMicrosKrw),
          "analysisVm.cost.remainingMicrosKrw",
        ),
      ],
    };
    const fields = fieldsBySection[sectionId];
    return fields
      ? {
          fields,
          blocked:
            vm.cost?.state === "RECONCILIATION_REQUIRED" &&
            scalar(vm.cost?.unknownReason) !== null,
          analysis: {
            visualizations: vm.visualizations,
            provenanceRows: vm.provenanceRows,
          },
        }
      : null;
  }
  if (screenId !== "OPS-004") return null;
  return ops004Fields(sectionId, data);
}
