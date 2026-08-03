import { bindPath } from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { isProviderControlOperationId } from "./provider-control-proposal";
import { operations } from "./screen-contract";
import { controlRequest } from "./screen-control";
import { isRecord, problemTitle, recordProperty } from "./screen-helpers";

export type ProviderOperationBinding = {
  valid: boolean;
  providerOperationId: string | null;
};

export function providerOperationBinding(
  actionKind: unknown,
  payload: Record<string, unknown>,
): ProviderOperationBinding {
  const hasProviderControl = Object.hasOwn(payload, "providerControl");
  if (actionKind !== "PROVIDER_CONTROL")
    return {
      valid: !hasProviderControl && payload.kind !== "PROVIDER_CONTROL",
      providerOperationId: null,
    };
  const providerControl = recordProperty(payload, "providerControl");
  const operationId = providerControl.operationId;
  return typeof operationId === "string" &&
    payload.kind === "PROVIDER_CONTROL" &&
    isProviderControlOperationId(operationId)
    ? { valid: true, providerOperationId: operationId }
    : { valid: false, providerOperationId: null };
}

export function submittedProviderOperationBinding(
  actionKind: unknown,
  payload: Record<string, unknown>,
  submittedProviderOperationId: unknown,
): ProviderOperationBinding {
  const binding = providerOperationBinding(actionKind, payload);
  if (!binding.valid) return binding;
  if (actionKind === "PROVIDER_CONTROL")
    return typeof submittedProviderOperationId === "string" &&
      submittedProviderOperationId === binding.providerOperationId
      ? binding
      : { valid: false, providerOperationId: null };
  return submittedProviderOperationId === undefined
    ? binding
    : { valid: false, providerOperationId: null };
}

export type ProviderDecisionAssurance = "ACTIVE_SESSION" | "STEP_UP";

export function providerDecisionAssurance(
  actionKind: unknown,
  providerOperationId: unknown,
  decision: unknown,
): ProviderDecisionAssurance | undefined {
  if (actionKind !== "PROVIDER_CONTROL") return undefined;
  const decisionKind = isRecord(decision) ? decision.kind : undefined;
  if (decisionKind !== "APPROVE") return "ACTIVE_SESSION";
  return providerOperationId === "testProviderConnection"
    ? "ACTIVE_SESSION"
    : "STEP_UP";
}

export function bindProviderDecision(
  actionKind: unknown,
  providerOperationId: unknown,
  decision: unknown,
): {
  decision: unknown;
  requiredAssuranceLevel?: ProviderDecisionAssurance;
} {
  const requiredAssuranceLevel = providerDecisionAssurance(
    actionKind,
    providerOperationId,
    decision,
  );
  if (!requiredAssuranceLevel) return { decision };
  if (!isRecord(decision) || decision.kind !== "APPROVE")
    return { decision, requiredAssuranceLevel };
  return {
    decision: {
      ...decision,
      assurance: requiredAssuranceLevel,
      stepUpAuthorizationId: null,
      assertedActionDigest: null,
      stepUpAt: null,
    },
    requiredAssuranceLevel,
  };
}

export type ApprovalTargetCheck =
  | { ok: true; canonical: Record<string, unknown> }
  | { ok: false; status: number; message: string };

export async function assertCurrentApprovalTarget(
  event: RequestEvent,
  input: Record<string, unknown>,
): Promise<ApprovalTargetCheck> {
  const proposalId = input.proposalId;
  const expectedVersion = input.expectedProposalVersion;
  const expectedDigest = input.expectedApprovalDigest;
  const assignmentId = input.assignmentId;
  const expectedAssignmentVersion = input.expectedAssignmentVersion;
  const actionKind = input.actionKind;
  const submittedProviderOperationId = input.providerOperationId;
  if (
    typeof proposalId !== "string" ||
    !proposalId.trim() ||
    typeof expectedVersion !== "number" ||
    !Number.isInteger(expectedVersion) ||
    expectedVersion < 1 ||
    typeof expectedDigest !== "string" ||
    !/^[0-9a-f]{64}$/.test(expectedDigest) ||
    typeof actionKind !== "string" ||
    !actionKind.trim() ||
    typeof assignmentId !== "string" ||
    !assignmentId.trim() ||
    typeof expectedAssignmentVersion !== "number" ||
    !Number.isInteger(expectedAssignmentVersion) ||
    expectedAssignmentVersion < 1
  ) {
    return {
      ok: false,
      status: 409,
      message:
        "승인 대상의 proposal·version·digest가 없어 결정을 기록할 수 없습니다.",
    };
  }
  const detailOperation = operations.get("getActionProposal");
  if (!detailOperation) {
    return {
      ok: false,
      status: 500,
      message: "승인 대상 상세 조회 계약이 없습니다.",
    };
  }
  const pathParams = { proposalId };
  const detailPath = bindPath(detailOperation.path, pathParams);
  const detail = await controlRequest(
    event,
    detailOperation,
    detailPath,
    "",
    undefined,
    undefined,
    undefined,
    undefined,
    pathParams,
  );
  if (!detail.response.ok) {
    return {
      ok: false,
      status: detail.response.status === 404 ? 409 : detail.response.status,
      message:
        detail.response.status === 404
          ? "승인 대상이 더 이상 존재하지 않습니다. 최신 목록을 다시 여세요."
          : problemTitle(detail.value, detail.response.status),
    };
  }
  const root = asRecord(detail.value);
  const proposal = asRecord(root?.proposal);
  const current =
    proposal && Object.keys(proposal).length > 0 ? proposal : (root ?? {});
  const currentVersion =
    typeof current.version === "number"
      ? current.version
      : typeof current.version === "string" && /^\d+$/.test(current.version)
        ? Number(current.version)
        : undefined;
  const currentDigest =
    typeof current.approvalDigest === "string"
      ? current.approvalDigest
      : undefined;
  const assignmentHistory = asRecord(root?.assignmentHistory);
  const assignments = Array.isArray(assignmentHistory?.items)
    ? assignmentHistory.items
    : root?.assignment && typeof root.assignment === "object"
      ? [root.assignment]
      : [];
  const currentAssignment = assignments
    .map(asRecord)
    .find((item) => item?.assignmentId === assignmentId);
  const currentAssignmentVersion =
    typeof currentAssignment?.version === "number"
      ? currentAssignment.version
      : typeof currentAssignment?.assignmentVersion === "number"
        ? currentAssignment.assignmentVersion
        : undefined;
  const currentActionKind =
    typeof current.actionKind === "string" ? current.actionKind : undefined;
  const providerBinding = submittedProviderOperationBinding(
    currentActionKind,
    asRecord(root?.payload) ?? {},
    submittedProviderOperationId,
  );
  const currentAssignmentId =
    typeof currentAssignment?.assignmentId === "string"
      ? currentAssignment.assignmentId
      : undefined;
  if (
    currentActionKind !== actionKind ||
    currentAssignmentId !== assignmentId ||
    currentVersion !== expectedVersion ||
    currentDigest !== expectedDigest ||
    currentAssignmentVersion !== expectedAssignmentVersion ||
    !providerBinding.valid
  ) {
    return {
      ok: false,
      status: 409,
      message:
        "승인 대상이 변경되었습니다. 최신 proposal version·digest를 확인한 뒤 다시 시도하세요.",
    };
  }
  return {
    ok: true,
    canonical: {
      proposalId,
      actionKind: currentActionKind,
      assignmentId: currentAssignmentId,
      expectedProposalVersion: currentVersion,
      expectedAssignmentVersion: currentAssignmentVersion,
      expectedApprovalDigest: currentDigest,
      ...(providerBinding.providerOperationId
        ? { providerOperationId: providerBinding.providerOperationId }
        : {}),
    },
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
