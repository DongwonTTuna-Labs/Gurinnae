import { bindPath } from "@gurine/config";
import {
  canonicalizeScreenViewModel,
  emptyScreenProjection,
  projectFetchedData,
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
  screen = canonicalizeScreenViewModel(screen);
  screen = { ...screen, contract: typedScreenViewModel(screen) };
  const session = sessionToken(event);
  const csrfToken = csrf(event);
  if (!session || !csrfToken) {
    return {
      screen,
      runtime: {
        state: "unauthenticated",
        pathname: event.url.pathname,
        search: event.url.search,
        data: {},
        projection: emptyScreenProjection(screen),
        errors: [],
        forms: {},
        allowedActionIds: localActionIds(screen),
        notice: "내부 화면을 사용하려면 로그인해야 합니다.",
        ...(csrfToken ? { csrfToken } : {}),
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
        search: event.url.search,
        data: {},
        projection: emptyScreenProjection(screen),
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
      // Route identifiers are authoritative inputs for query operations too.
      // The UI route for CAS-010 carries `caseId` in the path while the
      // control contract carries it as a required query parameter; CAS-011
      // similarly names the route segment `runId` and the API parameter
      // `agentRunId`.  Bind only these explicit contract aliases instead of
      // silently issuing an empty/unknown query.
      const operationSearchParams = new URLSearchParams(event.url.searchParams);
      for (const parameter of indexed.operation.parameters ?? []) {
        if (
          parameter.in !== "query" ||
          operationSearchParams.has(parameter.name)
        )
          continue;
        const pathValue =
          pathParams[parameter.name] ??
          (parameter.name === "agentRunId" ? pathParams.runId : undefined);
        if (pathValue !== undefined)
          operationSearchParams.set(parameter.name, pathValue);
      }
      const rawQuery = operationQuery(
        indexed.operation.parameters ?? [],
        operationSearchParams,
      );
      if (rawQuery === null) {
        // Query-backed command forms (for example SRC-006's estimate) are
        // intentionally rendered before their required range/filter values
        // exist.  A missing required query on the initial GET is therefore a
        // not-yet-requested operation, not a page error; once the user has
        // supplied any query value, malformed/incomplete input remains a
        // visible validation error.
        const queryParameters = (indexed.operation.parameters ?? []).filter(
          (parameter) => parameter.in === "query",
        );
        const hasAnyQueryValue = queryParameters.some((parameter) =>
          event.url.searchParams.has(parameter.name),
        );
        if (hasAnyQueryValue) {
          errors.push(
            `${contract.operation_id} 필수 검색 조건이 올바르지 않습니다.`,
          );
          firstErrorStatus ??= 422;
        }
        continue;
      }
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
  const assignmentHistory = recordValue(detail, "assignmentHistory");
  const assignmentItems = Array.isArray(assignmentHistory.items)
    ? assignmentHistory.items
    : detail.assignment && typeof detail.assignment === "object"
      ? [detail.assignment]
      : [];
  const assignment = assignmentItems.reduce<Record<string, unknown>>(
    (found, item) => {
      if (typeof item !== "object" || item === null) return found;
      const candidate = item as Record<string, unknown>;
      return typeof candidate.assignmentId === "string" ? candidate : found;
    },
    {},
  );
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
  const queueProjection = recordValue(data, "listActionApprovalQueue");
  const queueItems = Array.isArray(queueProjection.items)
    ? queueProjection.items
    : Array.isArray(data.listActionApprovalQueue)
      ? data.listActionApprovalQueue
      : [];
  const approvalQueue: NonNullable<ScreenRuntime["approvalQueue"]> =
    queueItems.flatMap((item) => {
      if (typeof item !== "object" || item === null) return [];
      const row = item as Record<string, unknown>;
      const candidate =
        typeof row.proposal === "object" && row.proposal !== null
          ? (row.proposal as Record<string, unknown>)
          : row;
      const proposalId =
        typeof candidate.proposalId === "string" &&
        /^[0-9a-f-]{16,128}$/i.test(candidate.proposalId)
          ? candidate.proposalId
          : null;
      const version =
        typeof candidate.version === "number" &&
        Number.isInteger(candidate.version) &&
        candidate.version >= 1
          ? candidate.version
          : typeof candidate.version === "string" &&
              /^\d+$/.test(candidate.version)
            ? Number(candidate.version)
            : null;
      const approvalDigest =
        typeof candidate.approvalDigest === "string" &&
        /^[0-9a-f]{64}$/i.test(candidate.approvalDigest)
          ? candidate.approvalDigest
          : null;
      if (proposalId === null || version === null || approvalDigest === null)
        return [];
      const state =
        typeof candidate.state === "string" ? candidate.state : "UNKNOWN";
      return [
        {
          proposalId,
          version,
          state,
          approvalDigest,
          href: `/internal/my-work?proposalId=${encodeURIComponent(proposalId)}`,
        },
      ];
    });
  const queueDigest = queueItems.reduce<string | undefined>((found, item) => {
    if (found || typeof item !== "object" || item === null) return found;
    const row = item as Record<string, unknown>;
    const candidate =
      typeof row.proposal === "object" && row.proposal !== null
        ? (row.proposal as Record<string, unknown>)
        : row;
    return candidate.proposalId === proposalId &&
      typeof candidate.approvalDigest === "string"
      ? candidate.approvalDigest
      : found;
  }, undefined);
  const digestCurrent =
    approvalDigest !== undefined &&
    queueDigest !== undefined &&
    queueDigest === approvalDigest;
  const selectedTarget: ScreenRuntime["selectedTarget"] =
    proposalId && proposalVersion !== undefined && approvalDigest
      ? {
          proposalId,
          actionKind:
            typeof proposal.actionKind === "string"
              ? proposal.actionKind
              : null,
          assignmentId:
            typeof assignment.assignmentId === "string"
              ? assignment.assignmentId
              : typeof proposal.assignmentId === "string"
                ? proposal.assignmentId
                : null,
          expectedProposalVersion: proposalVersion,
          expectedAssignmentVersion:
            typeof assignment.version === "number"
              ? assignment.version
              : typeof assignment.assignmentVersion === "number"
                ? assignment.assignmentVersion
                : null,
          expectedApprovalDigest: approvalDigest,
          handoffId:
            typeof detail.handoffId === "string"
              ? detail.handoffId
              : typeof assignment.handoffId === "string"
                ? assignment.handoffId
                : null,
          expectedHandoffVersion:
            typeof detail.handoffVersion === "number"
              ? detail.handoffVersion
              : typeof assignment.handoffVersion === "number"
                ? assignment.handoffVersion
                : null,
          expectedBindingDigest:
            typeof detail.bindingDigest === "string"
              ? detail.bindingDigest
              : typeof assignment.bindingDigest === "string"
                ? assignment.bindingDigest
                : null,
          digestCurrent,
          loadState: digestCurrent ? "READY" : "BLOCKED",
        }
      : undefined;
  if (selectedTarget) data.selectedTarget = selectedTarget;
  const runtime: ScreenRuntime = {
    csrfToken,
    state:
      firstErrorStatus === 403
        ? "forbidden"
        : firstErrorStatus === 409
          ? "conflict"
          : firstErrorStatus === 422
            ? "invalid-filter"
            : reviewRuntimeState(errors.length, resolved),
    pathname: event.url.pathname,
    search: event.url.search,
    // Raw operation DTOs stay server-side. The browser receives only the
    // closed, allowlisted projection below; this prevents accidental DTO
    // side-doors in generic or legacy components.
    data: {},
    projection: projectFetchedData(screen, data),
    errors,
    forms: formsFor(screen, event, data, new Set(allowedActionIds)),
    idempotencyKeys: actionIdempotencyKeys(screen, new Set(allowedActionIds)),
    allowedActionIds,
    ...(approvalQueue.length > 0 ? { approvalQueue } : {}),
    ...(selectedTarget ? { selectedTarget } : {}),
    ...(typeof actor.displayName === "string"
      ? { actorDisplayName: actor.displayName }
      : {}),
    ...(typeof resolvedSession.value.sessionExpiresAt === "string"
      ? { sessionExpiresAt: resolvedSession.value.sessionExpiresAt }
      : {}),
    ...(event.url.searchParams.get("notice")
      ? { notice: event.url.searchParams.get("notice") ?? "" }
      : {}),
  };
  return { screen, runtime };
}
