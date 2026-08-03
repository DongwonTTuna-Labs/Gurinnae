/**
 * INT-002's browser projection.  The control API's MyTasksPage and the
 * addendum approval queue are different envelopes; keeping this mapper
 * explicit prevents a generic first-record renderer from silently dropping
 * handoff evidence or selected-target bindings.
 */
export type Int002Fact = {
  label: string;
  value: string;
  unit?: string;
  sourceRevision?: string;
  locator?: string;
  uncertainty?: string;
  href?: string;
};

export type Int002Projection = {
  summary: string;
  status: string;
  facts: readonly Int002Fact[];
  asOf: string | null;
  provenance: string;
};

export type Int002Filters = {
  overdueOnly: boolean | null;
  taskStatus: readonly string[];
  taskType: readonly string[];
};

export type Int002SelectedTarget = {
  proposalId: string;
  actionKind: string | null;
  assignmentId: string | null;
  expectedProposalVersion: number;
  expectedAssignmentVersion: number | null;
  expectedApprovalDigest: string;
  handoffId: string | null;
  expectedHandoffVersion: number | null;
  expectedBindingDigest: string | null;
  digestCurrent: boolean;
  loadState: "READY" | "BLOCKED" | "EMPTY";
};

export type Int002ViewModel = {
  viewsObject: Int002Projection;
  tasksAnswer: Int002Projection;
  tasksNextAction: Int002Projection;
  taskFilters: Int002Filters;
  handoffState: Int002Projection;
  handoffEvidence: Int002Projection;
  handoffUnknown: Int002Projection;
  selectedTarget: Int002SelectedTarget | null;
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;

const string = (value: unknown): string | null =>
  typeof value === "string" && value.trim().length > 0 ? value : null;

const number = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= 1
    ? value
    : null;

const strings = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

function fact(
  label: string,
  value: unknown,
  extra: Partial<Int002Fact> = {},
): Int002Fact | null {
  const text =
    string(value) ??
    (typeof value === "number" || typeof value === "boolean"
      ? String(value)
      : null);
  return text === null ? null : { label, value: text, ...extra };
}

function projection(
  summary: string,
  status: string,
  facts: readonly (Int002Fact | null)[],
  asOf: string | null,
  provenance: string,
): Int002Projection {
  return {
    summary,
    status,
    facts: facts.filter((item): item is Int002Fact => item !== null),
    asOf,
    provenance,
  };
}

/** Maps only the fields authorised by Int002ScreenVmV1. Unknown DTO fields are ignored. */
export function toInt002ViewModel(
  data: Record<string, unknown>,
): Int002ViewModel {
  const tasks = record(data.listMyTasks) ?? {};
  const queue = record(data.listActionApprovalQueue) ?? {};
  const taskItems = Array.isArray(tasks.items) ? tasks.items : [];
  const approvalItems = Array.isArray(queue.items) ? queue.items : [];
  const taskAsOf = string(tasks.asOf);
  const queueAsOf = string(queue.asOf);
  const taskFacts = taskItems.flatMap((item, index) => {
    const row = record(item);
    if (!row) return [];
    const href = string(row.href);
    return [
      fact(`작업 ${index + 1}`, row.title ?? row.id, href ? { href } : {}),
      fact("상태", row.status),
      fact("기한", row.dueAt),
      fact(
        "대상",
        row.objectType && row.objectId
          ? `${String(row.objectType)} · ${String(row.objectId)}`
          : null,
      ),
    ];
  });
  const proposalFacts = approvalItems.flatMap((item, index) => {
    const row = record(item);
    const proposal = record(row?.proposal) ?? row;
    if (!proposal) return [];
    return [
      fact(`승인 제안 ${index + 1}`, proposal.proposalId),
      fact("제안 상태", proposal.state),
      fact("제안 버전", proposal.version),
      fact("승인 지문", proposal.approvalDigest),
    ];
  });
  const filters = record(tasks.appliedFilters) ?? {};
  // Selection is an explicit user interaction. Never silently bind the first
  // queue item to a destructive command. BFFs may provide a separately
  // validated selectedTarget projection; otherwise the action remains blocked.
  const selected = record(data.selectedTarget);
  const selectedProposalId = string(selected?.proposalId);
  const selectedProposalVersion = number(selected?.expectedProposalVersion);
  const selectedApprovalDigest = string(selected?.expectedApprovalDigest);
  const handoff = record(selected?.handoff);
  const handoffId = string(selected?.handoffId) ?? string(handoff?.handoffId);
  const expectedHandoffVersion =
    number(selected?.expectedHandoffVersion) ?? number(handoff?.version);
  const expectedBindingDigest =
    string(selected?.expectedBindingDigest) ?? string(handoff?.bindingDigest);
  const selectedDigestCurrent =
    selectedApprovalDigest !== null &&
    /^[0-9a-f]{64}$/i.test(selectedApprovalDigest);
  const selectedTarget =
    selectedProposalId &&
    selectedProposalVersion !== null &&
    selectedApprovalDigest
      ? {
          proposalId: selectedProposalId,
          actionKind: string(selected?.actionKind),
          assignmentId: string(selected?.assignmentId),
          expectedProposalVersion: selectedProposalVersion,
          expectedAssignmentVersion: number(
            selected?.expectedAssignmentVersion,
          ),
          expectedApprovalDigest: selectedApprovalDigest,
          handoffId,
          expectedHandoffVersion,
          expectedBindingDigest,
          digestCurrent: selectedDigestCurrent,
          loadState: selectedDigestCurrent
            ? ("READY" as const)
            : ("BLOCKED" as const),
        }
      : null;
  const taskStatus = strings(filters.taskStatus ?? filters.status);
  const taskType = strings(filters.taskType ?? filters.type);
  return {
    viewsObject: projection(
      "내 작업의 오늘·지연·차단 범위",
      taskItems.length > 0 ? "READY" : "EMPTY",
      [fact("확인된 작업", taskItems.length), fact("기준 시각", taskAsOf)],
      taskAsOf,
      "listMyTasks.$projection.views_object",
    ),
    tasksAnswer: projection(
      "왜 이 작업이 나에게 필요한지와 기한",
      taskItems.length > 0 ? "READY" : "EMPTY",
      taskFacts,
      taskAsOf,
      "listMyTasks.$projection.tasks_answer",
    ),
    tasksNextAction: projection(
      "다음으로 수행할 작업",
      taskItems.length > 0 ? "READY" : "EMPTY",
      [fact("다음 행동", taskItems.length > 0 ? "선택한 작업 열기" : null)],
      taskAsOf,
      "listMyTasks.$projection.tasks_next_action",
    ),
    taskFilters: {
      overdueOnly:
        typeof filters.overdueOnly === "boolean" ? filters.overdueOnly : null,
      taskStatus,
      taskType,
    },
    handoffState: projection(
      "외부 전달 승인 대기 상태",
      approvalItems.length > 0 ? "READY" : "EMPTY",
      [
        fact("대기 중인 승인", approvalItems.length),
        fact("기준 시각", queueAsOf),
      ],
      queueAsOf,
      "listActionApprovalQueue",
    ),
    handoffEvidence: projection(
      "승인 제안·대상·버전·지문",
      approvalItems.length > 0 ? "READY" : "EMPTY",
      proposalFacts,
      queueAsOf,
      "listActionApprovalQueue.items",
    ),
    handoffUnknown: projection(
      "제안 내용과 외부 채널 권한은 상세 승인 화면에서 확인",
      approvalItems.length > 0 ? "REVIEW_REQUIRED" : "EMPTY",
      [
        fact(
          "상세 제안",
          approvalItems.length > 0 ? "승인 전 상세 내용 확인 필요" : null,
        ),
      ],
      queueAsOf,
      "getActionProposal / ActionApprovalBindingV1",
    ),
    selectedTarget,
  };
}
