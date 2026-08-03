import { timingSafeEqual } from "node:crypto";
import {
  bindPath,
  canonicalJsonSha256,
  formPayload,
  type IndexedOperation,
  operationFields,
} from "@gurine/config";
import type { ScreenViewModel } from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { requestContext } from "./actor-context";
import { setPending, setStepUpTransaction } from "./cookies";
import { operations } from "./screen-contract";
import { controlRequest, identityCall } from "./screen-control";
import {
  actionPreset,
  aggregateType,
  bindRouteValues,
  csrf,
  definedParams,
  epochSeconds,
  findAggregateId,
  formIdempotencyKey,
  hash,
  isAnonymousProofAction,
  isRedirect,
  normalize,
  problemTitle,
  queryString,
  renderRoute,
  safeInternalReturnTo,
  sameOrigin,
  sessionToken,
  stringExtension,
  stringProperty,
  stringValue,
} from "./screen-helpers";

function csrfMatches(
  candidate: FormDataEntryValue | null,
  expected: string,
): boolean {
  if (typeof candidate !== "string") return false;
  const actual = Buffer.from(candidate, "utf8");
  const target = Buffer.from(expected, "utf8");
  return actual.length === target.length && timingSafeEqual(actual, target);
}

import type { ElevatedAuthorization, PendingAction } from "./screen-types";

export function screenActions(screen: ScreenViewModel): Actions {
  return Object.fromEntries(
    screen.actions.map((action) => [
      action.id,
      async (event: RequestEvent) => runAction(event, screen, action),
    ]),
  );
}

async function runAction(
  event: RequestEvent,
  screen: ScreenViewModel,
  action: ScreenViewModel["actions"][number],
) {
  const operationId = stringProperty(action, "operation_id");
  if (!operationId)
    throw redirect(303, renderRoute(screen.route, event.params));
  const indexed = operations.get(operationId);
  if (!indexed) return fail(500, { message: "작업 계약을 찾지 못했습니다." });
  if (operationId === "startOidcLogin" && isAnonymousProofAction(action)) {
    if (!sameOrigin(event)) return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    const returnTo = safeInternalReturnTo(
      event.url.searchParams.get("returnTo"),
      event.url,
    );
    throw redirect(303, `/auth/login?returnTo=${encodeURIComponent(returnTo)}`);
  }
  const session = sessionToken(event);
  const csrfToken = csrf(event);
  if (!session || !csrfToken)
    throw redirect(
      303,
      `/auth/login?returnTo=${encodeURIComponent(event.url.pathname)}`,
    );
  try {
    const form = await event.request.formData();
    if (!sameOrigin(event)) return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    if (!csrfMatches(form.get("csrfToken"), csrfToken)) {
      return fail(403, { message: "CSRF_TOKEN_STALE" });
    }
    const idempotencyKey = formIdempotencyKey(form);
    const fields = operationFields(
      indexed,
      event.params,
      actionPreset(action),
    ).map((field) => {
      if (indexed.operation.operationId !== "decideJourneyHandoff")
        return field;
      if (field.name === "reasonCode") {
        return {
          ...field,
          required: false,
          type: "text" as const,
          options: [
            "CAPABILITY_UNAVAILABLE",
            "OBJECT_SCOPE_MISMATCH",
            "CONFLICT_OF_INTEREST",
            "WORKLOAD_CAPACITY",
            "DEPENDENCY_BLOCKED",
            "SUBJECT_INVALID",
            "OWNER_UNAVAILABLE",
            "POLICY_BLOCKED",
            "RECEIVER_DECLINED",
          ],
        };
      }
      if (field.name === "reason") return { ...field, required: false };
      return field;
    });
    const input = bindRouteValues(
      normalize(formPayload(form, fields, actionPreset(action))),
      event.params,
    );
    // A browser form is an untrusted transport.  Approval commands must be
    // bound to the proposal version and digest that the control API serves at
    // the moment the decision is submitted; accepting hidden fields alone
    // would let a stale tab (or a tampered request) present an arbitrary
    // proposal/version pair to the step-up flow.  The control API performs the
    // final transactional check too, but this BFF preflight gives the user a
    // deterministic conflict before any step-up authorization is created.
    if (indexed.operation.operationId === "submitActionDecision") {
      const targetCheck = await assertCurrentApprovalTarget(event, input);
      if (!targetCheck.ok) {
        return fail(targetCheck.status, { message: targetCheck.message });
      }
      Object.assign(input, targetCheck.canonical);
    }
    if (indexed.operation.operationId === "decideJourneyHandoff") {
      const decision = input.decision;
      if (decision === "ACKNOWLEDGE") {
        // ACK has a required nullable shape: omission is not equivalent to
        // null and must not reach the control API.
        input.reasonCode = null;
        input.reason = null;
      }
    }
    const pathParams: Record<string, string | undefined> = { ...event.params };
    for (const name of pathParameterNames(indexed.path)) {
      if (pathParams[name]) continue;
      const value = (input as Record<string, unknown>)[name];
      if (typeof value === "string" && value.trim()) pathParams[name] = value;
    }
    const unresolved = pathParameterNames(indexed.path).filter(
      (name) => !pathParams[name],
    );
    if (unresolved.length > 0)
      return fail(409, {
        message: `선택한 대상이 없습니다: ${unresolved.join(", ")}`,
      });
    // At this point every parameter required by the contract has been
    // resolved.  Narrow the transport map before handing it to the generated
    // client; keeping the preflight map partial avoids accidentally treating
    // an omitted form value as a valid path segment while the generated
    // client correctly requires concrete strings.
    const boundPathParams: Record<string, string> = {};
    for (const [name, value] of Object.entries(pathParams)) {
      if (typeof value === "string") boundPathParams[name] = value;
    }
    const path = bindPath(indexed.path, boundPathParams);
    // The OpenAPI operation catalog describes transport capabilities, while
    // the screen action owns the user-facing assurance requirement.  The
    // addendum routes intentionally keep STEP_UP on the action metadata, so
    // do not silently downgrade a decision to an active-session command when
    // the generated operation has no x-assurance-level extension.
    const assurance =
      stringExtension(indexed, "x-assurance-level") ??
      stringProperty(action, "assurance_level") ??
      (action.step_up_required === true ? "STEP_UP" : "ACTIVE_SESSION");
    const operationKind = stringExtension(indexed, "x-operation-kind");
    if (assurance === "STEP_UP") {
      return beginStepUp(
        event,
        indexed,
        path,
        input,
        idempotencyKey,
        event.url.pathname,
        boundPathParams,
      );
    }
    const queryOperation =
      indexed.method === "GET" || operationKind === "QUERY";
    const rawQuery = queryOperation ? queryString(input) : "";
    const result = queryOperation
      ? await controlRequest(
          event,
          indexed,
          path,
          rawQuery,
          undefined,
          undefined,
          undefined,
          undefined,
          boundPathParams,
        )
      : await controlRequest(
          event,
          indexed,
          path,
          "",
          input,
          idempotencyKey,
          undefined,
          undefined,
          boundPathParams,
        );
    if (!result.response.ok)
      return fail(result.response.status, {
        message: problemTitle(result.value, result.response.status),
      });
    const destination = new URL(
      renderRoute(screen.route, event.params),
      event.url,
    );
    if (queryOperation) {
      for (const [name, value] of new URLSearchParams(rawQuery))
        destination.searchParams.append(name, value);
    }
    destination.searchParams.set("notice", `${action.label} 완료`);
    throw redirect(303, `${destination.pathname}${destination.search}`);
  } catch (error) {
    if (isRedirect(error)) throw error;
    return fail(400, {
      message:
        error instanceof Error ? error.message : "요청을 처리하지 못했습니다.",
    });
  }
}

type ApprovalTargetCheck =
  | { ok: true; canonical: Record<string, unknown> }
  | { ok: false; status: number; message: string };

async function assertCurrentApprovalTarget(
  event: RequestEvent,
  input: Record<string, unknown>,
): Promise<ApprovalTargetCheck> {
  const proposalId = input.proposalId;
  const expectedVersion = input.expectedProposalVersion;
  const expectedDigest = input.expectedApprovalDigest;
  const assignmentId = input.assignmentId;
  const expectedAssignmentVersion = input.expectedAssignmentVersion;
  const actionKind = input.actionKind;
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
  const currentAssignmentId =
    typeof currentAssignment?.assignmentId === "string"
      ? currentAssignment.assignmentId
      : undefined;
  if (
    currentActionKind !== actionKind ||
    currentAssignmentId !== assignmentId ||
    currentVersion !== expectedVersion ||
    currentDigest !== expectedDigest ||
    currentAssignmentVersion !== expectedAssignmentVersion
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
    },
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function pathParameterNames(path: string): string[] {
  return [...path.matchAll(/\{([^}]+)\}/g)]
    .map((match) => match[1])
    .filter((item): item is string => Boolean(item));
}

async function beginStepUp(
  event: RequestEvent,
  indexed: IndexedOperation,
  path: string,
  body: Record<string, unknown>,
  idempotencyKey: string,
  returnTo: string,
  pathParams: Record<string, string | undefined>,
) {
  const session = sessionToken(event);
  const csrfToken = csrf(event);
  if (!session || !csrfToken) throw redirect(303, "/auth/login");
  const bodyBytes = JSON.stringify(body);
  const aggregateId = findAggregateId(body, event.params);
  const actionContext = {
    operationId: indexed.operation.operationId,
    aggregateType: aggregateType(indexed.operation.operationId),
    aggregateId,
    expectedVersion:
      typeof body.expectedVersion === "number" ? body.expectedVersion : 1,
    businessPayloadSha256: hash(bodyBytes),
    idempotencyKeySha256: hash(idempotencyKey),
  };
  const actionDigest = canonicalJsonSha256(actionContext);
  const pending: PendingAction = {
    operationId: indexed.operation.operationId,
    path,
    body,
    bodyBytes,
    idempotencyKey,
    actionContext,
    returnTo,
    pathParams: definedParams(pathParams),
  };
  const result = await identityCall(
    event,
    "/internal/v1/oidc/step-up-transactions",
    {
      opaqueSessionToken: session,
      csrfToken,
      returnTo,
      callbackUri: new URL("/auth/step-up/callback", event.url).toString(),
      context: requestContext(event),
      actionContext,
    },
  );
  if (!result.response.ok)
    return fail(result.response.status, {
      message: problemTitle(result.value, result.response.status),
    });
  const transaction = stringValue(result.value, "transactionCookieValue");
  const authorizationUrl = stringValue(result.value, "authorizationUrl");
  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = epochSeconds(stringValue(result.value, "expiresAt"));
  setStepUpTransaction(event, {
    v: 1,
    typ: "step-up-transaction",
    transactionCookieValue: transaction,
    idempotencyKey,
    actionDigest,
    issuedAt,
    expiresAt,
  });
  setPending(event, pending);
  throw redirect(303, authorizationUrl);
}

export async function executePending(
  event: RequestEvent,
  pending: PendingAction,
  elevated: ElevatedAuthorization,
) {
  const indexed = operations.get(pending.operationId);
  if (!indexed) throw new Error("대기 중인 작업 계약을 찾지 못했습니다.");
  let result: Awaited<ReturnType<typeof controlRequest>> | undefined;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    result = await controlRequest(
      event,
      indexed,
      pending.path,
      "",
      pending.body,
      pending.idempotencyKey,
      pending.actionContext,
      elevated,
      pending.pathParams,
    );
    if (![502, 503, 504].includes(result.response.status)) break;
  }
  if (!result) throw new Error("step-up command did not produce a response");
  if (![502, 503, 504].includes(result.response.status)) {
    await identityCall(event, "/internal/v1/step-up-authorizations/close", {
      opaqueSessionToken: sessionToken(event),
      stepUpAuthorizationToken: elevated.stepUpAuthorizationToken,
      actionDigest: elevated.actionDigest,
      idempotencyKeySha256: elevated.idempotencyKeySha256,
      context: requestContext(event),
    });
  }
  return result;
}
