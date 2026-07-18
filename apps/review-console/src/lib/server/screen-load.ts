import { bindPath } from "@gurine/config";
import {
  type ScreenRuntime,
  type ScreenViewModel,
  typedScreenViewModel,
} from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { reviewRuntimeState } from "$lib/view-models/runtime";
import { requestContext } from "./actor-context";
import { clearAuth } from "./cookies";
import { operations } from "./screen-contract";
import { controlRequest, identityCall } from "./screen-control";
import {
  actionAllowed,
  actionIdempotencyKeys,
  csrf,
  definedParams,
  formsFor,
  localActionIds,
  operationQuery,
  problemTitle,
  recordValue,
  sessionToken,
  stringArray,
} from "./screen-helpers";

export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  screen = { ...screen, contract: typedScreenViewModel(screen) };
  const session = sessionToken(event);
  const csrfToken = csrf(event);
  if (!session || !csrfToken) {
    return {
      screen,
      runtime: {
        state: "unauthenticated",
        pathname: event.url.pathname,
        data: {},
        errors: [],
        forms: {},
        allowedActionIds: localActionIds(screen),
        notice: "내부 화면을 사용하려면 로그인해야 합니다.",
      } satisfies ScreenRuntime,
    };
  }
  const resolvedSession = await identityCall(
    event,
    "/internal/v1/sessions/resolve",
    {
      opaqueSessionToken: session,
      context: requestContext(event),
    },
  );
  if (!resolvedSession.response.ok) {
    if (resolvedSession.response.status === 401) clearAuth(event);
    return {
      screen,
      runtime: {
        state:
          resolvedSession.response.status === 401
            ? "unauthenticated"
            : resolvedSession.response.status === 403
              ? "forbidden"
              : resolvedSession.response.status === 409
                ? "conflict"
                : "error",
        pathname: event.url.pathname,
        data: {},
        errors: [
          problemTitle(resolvedSession.value, resolvedSession.response.status),
        ],
        forms: {},
        allowedActionIds: localActionIds(screen),
      } satisfies ScreenRuntime,
    };
  }
  const actor = recordValue(resolvedSession.value, "actor");
  const capabilities = stringArray(actor.capabilities);
  const allowedActionIds = screen.actions
    .filter((action) => actionAllowed(action, capabilities))
    .map((action) => action.id);
  const data: Record<string, unknown> = {};
  const errors: string[] = [];
  let firstErrorStatus: number | undefined;
  let resolved = 0;
  const selectedProposalId = event.url.searchParams.get("proposalId")?.trim();
  const selectedExecutionId = event.url.searchParams.get("executionId")?.trim();
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET") continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) continue;
    const selectedId =
      contract.operation_id === "getActionProposal"
        ? selectedProposalId
        : contract.operation_id === "getActionExecutionReceipt"
          ? selectedExecutionId
          : undefined;
    if (
      (!contract.blocking && !selectedId) ||
      ((contract.operation_id === "getActionProposal" ||
        contract.operation_id === "getActionExecutionReceipt") &&
        !selectedId)
    )
      continue;
    if (selectedId !== undefined && !/^[0-9a-f-]{16,128}$/i.test(selectedId)) {
      errors.push(`${contract.operation_id} 대상 식별자가 올바르지 않습니다.`);
      firstErrorStatus ??= 400;
      continue;
    }
    try {
      const pathParams = definedParams({
        ...event.params,
        ...(contract.operation_id === "getActionProposal" && selectedId
          ? { proposalId: selectedId }
          : {}),
        ...(contract.operation_id === "getActionExecutionReceipt" && selectedId
          ? { executionId: selectedId }
          : {}),
      });
      const path = bindPath(indexed.path, pathParams);
      const rawQuery = operationQuery(
        indexed.operation.parameters ?? [],
        event.url.searchParams,
      );
      if (rawQuery === null) continue;
      const result = await controlRequest(
        event,
        indexed,
        path,
        rawQuery,
        undefined,
        undefined,
        undefined,
        undefined,
        pathParams,
      );
      if (!result.response.ok) {
        firstErrorStatus ??= result.response.status;
        throw new Error(problemTitle(result.value, result.response.status));
      }
      data[contract.operation_id] = result.value;
      resolved += 1;
    } catch (error) {
      errors.push(
        error instanceof Error
          ? error.message
          : `${contract.operation_id} 요청 실패`,
      );
    }
  }
  const detail = recordValue(data, "getActionProposal");
  const detailProposal = recordValue(detail, "proposal");
  const proposal =
    Object.keys(detailProposal).length > 0 ? detailProposal : detail;
  const assignment = recordValue(detail, "assignment");
  const proposalId =
    typeof proposal.proposalId === "string"
      ? proposal.proposalId
      : selectedProposalId;
  const proposalVersion =
    typeof proposal.version === "number" && Number.isInteger(proposal.version)
      ? proposal.version
      : typeof proposal.version === "string" && /^\d+$/.test(proposal.version)
        ? Number(proposal.version)
        : undefined;
  const approvalDigest =
    typeof proposal.approvalDigest === "string" &&
    /^[0-9a-f]{64}$/i.test(proposal.approvalDigest)
      ? proposal.approvalDigest
      : undefined;
  if (proposalId && proposalVersion !== undefined && approvalDigest) {
    data.selectedTarget = {
      proposalId,
      actionKind:
        typeof proposal.actionKind === "string" ? proposal.actionKind : null,
      assignmentId:
        typeof assignment.assignmentId === "string"
          ? assignment.assignmentId
          : typeof proposal.assignmentId === "string"
            ? proposal.assignmentId
            : null,
      expectedProposalVersion: proposalVersion,
      expectedAssignmentVersion:
        typeof assignment.assignmentVersion === "number"
          ? assignment.assignmentVersion
          : typeof proposal.assignmentVersion === "number"
            ? proposal.assignmentVersion
            : null,
      expectedApprovalDigest: approvalDigest,
      digestCurrent: true,
      loadState: "READY",
    };
  }
  const runtime: ScreenRuntime = {
    state:
      firstErrorStatus === 403
        ? "forbidden"
        : firstErrorStatus === 409
          ? "conflict"
          : reviewRuntimeState(errors.length, resolved),
    pathname: event.url.pathname,
    data,
    errors,
    forms: formsFor(screen, event, data, new Set(allowedActionIds)),
    idempotencyKeys: actionIdempotencyKeys(screen, new Set(allowedActionIds)),
    allowedActionIds,
    ...(typeof actor.displayName === "string"
      ? { actorDisplayName: actor.displayName }
      : {}),
    ...(typeof resolvedSession.value.sessionExpiresAt === "string"
      ? { sessionExpiresAt: resolvedSession.value.sessionExpiresAt }
      : {}),
    csrfToken,
    ...(event.url.searchParams.get("notice")
      ? { notice: event.url.searchParams.get("notice") ?? "" }
      : {}),
  };
  return { screen, runtime };
}
