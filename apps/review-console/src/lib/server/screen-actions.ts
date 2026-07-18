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
  isRedirect,
  normalize,
  problemTitle,
  queryString,
  renderRoute,
  sessionToken,
  stringExtension,
  stringProperty,
  stringValue,
} from "./screen-helpers";
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
  if (!indexed) return fail(500, { message: "operation contract missing" });
  const session = sessionToken(event);
  const csrfToken = csrf(event);
  if (!session || !csrfToken)
    throw redirect(
      303,
      `/auth/login?returnTo=${encodeURIComponent(event.url.pathname)}`,
    );
  try {
    const form = await event.request.formData();
    if (form.get("csrfToken") !== csrfToken)
      return fail(403, { message: "CSRF_TOKEN_STALE" });
    const idempotencyKey = formIdempotencyKey(form);
    const fields = operationFields(indexed, event.params, actionPreset(action));
    const input = bindRouteValues(
      normalize(formPayload(form, fields, actionPreset(action))),
      event.params,
    );
    const pathParams: Record<string, string | undefined> = { ...event.params };
    for (const name of pathParameterNames(indexed.path)) {
      if (pathParams[name]) continue;
      const value = (input as Record<string, unknown>)[name];
      if (typeof value === "string" && value.trim()) pathParams[name] = value;
    }
    const unresolved = pathParameterNames(indexed.path).filter((name) => !pathParams[name]);
    if (unresolved.length > 0)
      return fail(409, { message: `선택한 대상이 없습니다: ${unresolved.join(", ")}` });
    const path = bindPath(indexed.path, pathParams);
    const assurance =
      stringExtension(indexed, "x-assurance-level") ?? "ACTIVE_SESSION";
    const operationKind = stringExtension(indexed, "x-operation-kind");
    if (assurance === "STEP_UP") {
      return beginStepUp(
        event,
        indexed,
        path,
        input,
        idempotencyKey,
        event.url.pathname,
        pathParams,
      );
    }
    const queryOperation =
      indexed.method === "GET" || operationKind === "QUERY";
    const rawQuery = queryOperation ? queryString(input) : "";
    const result = queryOperation
      ? await controlRequest(event, indexed, path, rawQuery)
      : await controlRequest(event, indexed, path, "", input, idempotencyKey);
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

function pathParameterNames(path: string): string[] {
  return [...path.matchAll(/\{([^}]+)\}/g)].map((match) => match[1]).filter((item): item is string => Boolean(item));
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
  if (!indexed) throw new Error("pending operation contract missing");
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
