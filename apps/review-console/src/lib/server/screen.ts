import { createHash, randomUUID } from "node:crypto";
import { invokeControlOperation } from "@gurine/api-client-control";
import { invokeIdentityOperation } from "@gurine/api-client-identity-internal";
import {
  bindPath,
  canonicalJsonSha256,
  downstreamRequestBinding,
  formPayload,
  type IndexedOperation,
  indexOperations,
  type OpenApiDocument,
  operationFields,
  optimisticVersion,
  requiredServerValue,
} from "@gurine/config";
import type { ScreenRuntime, ScreenViewModel } from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { reviewRuntimeState } from "$lib/view-models/runtime";
import controlOpenApi from "../../../../../specs/generated/control-api.openapi.json";
import identityOpenApi from "../../../../../specs/generated/identity-provider.openapi.json";
import { requestContext } from "./actor-context";
import {
  clearAuth,
  readInternalSession,
  setPending,
  setStepUpTransaction,
} from "./cookies";
import { identityServiceFetch } from "./service-assertion";

export { requestContext } from "./actor-context";

const operations = indexOperations([
  controlOpenApi as OpenApiDocument,
  identityOpenApi as OpenApiDocument,
]);

type PendingAction = {
  operationId: string;
  path: string;
  body: Record<string, unknown>;
  bodyBytes: string;
  idempotencyKey: string;
  actionContext: Record<string, unknown>;
  returnTo: string;
  pathParams: Record<string, string>;
};

type ElevatedAuthorization = {
  actionDigest: string;
  stepUpAuthorizationToken: string;
  idempotencyKeySha256: string;
  csrfToken: string;
};

export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
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
          resolvedSession.response.status === 401 ? "unauthenticated" : "error",
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
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET" || !contract.blocking) continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) continue;
    try {
      const path = bindPath(indexed.path, event.params);
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
      );
      if (!result.response.ok)
        throw new Error(problemTitle(result.value, result.response.status));
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
  const runtime: ScreenRuntime = {
    state: reviewRuntimeState(errors.length, resolved),
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
    const fields = operationFields(
      indexed,
      event.params,
      recordProperty(action, "preset"),
    );
    const input = bindRouteValues(
      normalize(formPayload(form, fields, recordProperty(action, "preset"))),
      event.params,
    );
    const path = bindPath(indexed.path, event.params);
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

async function beginStepUp(
  event: RequestEvent,
  indexed: IndexedOperation,
  path: string,
  body: Record<string, unknown>,
  idempotencyKey: string,
  returnTo: string,
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
    pathParams: definedParams(event.params),
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

async function controlRequest(
  event: RequestEvent,
  indexed: IndexedOperation,
  path: string,
  rawQuery: string,
  body?: Record<string, unknown>,
  idempotencyKey?: string,
  actionContext?: Record<string, unknown>,
  elevated?: ElevatedAuthorization,
  pathParams: Record<string, string> = definedParams(event.params),
) {
  const session = sessionToken(event);
  if (!session) throw new Error("SESSION_NOT_ACTIVE");
  const assurance =
    stringExtension(indexed, "x-assurance-level") ?? "ACTIVE_SESSION";
  const authenticatedFetch: typeof globalThis.fetch = async (
    resource,
    init,
  ) => {
    const request =
      resource instanceof Request ? resource : new Request(resource, init);
    const url = new URL(request.url);
    if (url.pathname !== path)
      throw new Error(
        "generated Control path does not match the bound action path",
      );
    const bodyBytes = new Uint8Array(await request.clone().arrayBuffer());
    const requestIdempotency =
      request.headers.get("idempotency-key") ?? undefined;
    const binding = downstreamRequestBinding({
      method: request.method,
      path: url.pathname,
      ...(url.search.length > 1 ? { rawQuery: url.search.slice(1) } : {}),
      body: bodyBytes,
      contentType: request.headers.get("content-type") ?? "",
      ...(requestIdempotency ? { idempotencyKey: requestIdempotency } : {}),
    });
    const assertion = await identityCall(
      event,
      "/internal/v1/actor-assertions",
      {
        opaqueSessionToken: session,
        downstreamRequest: binding,
        operationId: indexed.operation.operationId,
        requiredCapability: stringExtension(indexed, "x-capability") ?? "",
        actionContext: actionContext ?? null,
        actionDigest: elevated?.actionDigest ?? null,
        stepUpAuthorizationToken: elevated?.stepUpAuthorizationToken ?? null,
        context: requestContext(event),
        requiredAssuranceLevel: assurance,
      },
    );
    if (!assertion.response.ok) return assertion.response;
    const headers = new Headers(request.headers);
    headers.set(
      "x-gurine-actor-assertion",
      stringValue(assertion.value, "actorAssertion"),
    );
    headers.set("x-request-id", randomUUID());
    return event.fetch(new Request(request, { headers }));
  };
  const result = await invokeControlOperation({
    operationId: indexed.operation.operationId,
    baseUrl: requiredServerValue(env, "CONTROL_API_INTERNAL_URL"),
    fetch: authenticatedFetch,
    path: pathParams,
    query: queryRecord(rawQuery),
    ...(body !== undefined ? { body } : {}),
    ...(idempotencyKey
      ? { headers: { "Idempotency-Key": idempotencyKey } }
      : {}),
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  return { response, value };
}

export async function identityCall(
  event: RequestEvent,
  path: string,
  body: Record<string, unknown>,
) {
  const operationId = identityOperations[path];
  if (!operationId)
    throw new Error(`generated identity operation for ${path} is missing`);
  const result = await invokeIdentityOperation({
    operationId,
    baseUrl: requiredServerValue(env, "IDENTITY_API_INTERNAL_URL"),
    fetch: identityServiceFetch(event, env),
    body,
    headers: { "Idempotency-Key": randomUUID() },
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  return { response, value };
}

const identityOperations: Readonly<Record<string, string>> = {
  "/internal/v1/oidc/login-transactions": "createLoginTransaction",
  "/internal/v1/oidc/login-callbacks": "consumeLoginCallback",
  "/internal/v1/oidc/step-up-transactions": "createStepUpTransaction",
  "/internal/v1/oidc/step-up-callbacks": "consumeStepUpCallback",
  "/internal/v1/sessions/resolve": "resolveInternalSession",
  "/internal/v1/sessions/revoke": "revokeInternalSession",
  "/internal/v1/security-management-redirect":
    "getSecurityManagementRedirectInternal",
  "/internal/v1/actor-assertions": "issueActorAssertion",
  "/internal/v1/step-up-authorizations/close": "closeStepUpAuthorization",
};

function formsFor(
  screen: ScreenViewModel,
  event: RequestEvent,
  data: Record<string, unknown>,
  allowed?: ReadonlySet<string>,
) {
  return Object.fromEntries(
    screen.actions
      .filter((action) => !allowed || allowed.has(action.id))
      .map((action) => {
        const operationId = stringProperty(action, "operation_id");
        const indexed = operationId ? operations.get(operationId) : undefined;
        const explicit = recordProperty(action, "preset");
        const expectedVersion = optimisticVersion(data);
        const preset = {
          ...(expectedVersion !== undefined ? { expectedVersion } : {}),
          ...explicit,
        };
        return [
          action.id,
          indexed ? operationFields(indexed, event.params, preset) : [],
        ];
      }),
  );
}
function localActionIds(screen: ScreenViewModel): string[] {
  return screen.actions
    .filter((action) => action.local_only === true)
    .map((action) => action.id);
}
function actionIdempotencyKeys(
  screen: ScreenViewModel,
  allowed: ReadonlySet<string>,
): Readonly<Record<string, string>> {
  return Object.fromEntries(
    screen.actions
      .filter(
        (action) =>
          allowed.has(action.id) && stringProperty(action, "operation_id"),
      )
      .map((action) => [action.id, randomUUID()]),
  );
}
function formIdempotencyKey(form: FormData): string {
  const value = form.get("idempotencyKey");
  if (
    typeof value !== "string" ||
    value.length < 8 ||
    value.length > 200 ||
    !/^[\x20-\x7e]+$/.test(value)
  )
    throw new Error("멱등성 키가 없거나 올바르지 않습니다.");
  return value;
}
function actionAllowed(
  action: ScreenViewModel["actions"][number],
  capabilities: readonly string[],
): boolean {
  const capability = stringProperty(action, "capability");
  return (
    action.local_only === true ||
    !capability ||
    capability === "none" ||
    capabilities.includes(capability)
  );
}
function recordValue(
  value: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const item = value[key];
  return isRecord(item) ? item : {};
}
function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}
function operationQuery(
  parameters: Array<{ name: string; in: string; required?: boolean }>,
  current: URLSearchParams,
): string | null {
  const query = new URLSearchParams();
  for (const parameter of parameters.filter((item) => item.in === "query")) {
    const values = current.getAll(parameter.name);
    if (parameter.required && values.length === 0) return null;
    for (const value of values) query.append(parameter.name, value);
  }
  return query.toString();
}
function queryRecord(rawQuery: string): Record<string, unknown> {
  const output: Record<string, unknown> = {};
  const query = new URLSearchParams(rawQuery);
  for (const key of new Set(query.keys())) {
    const values = query.getAll(key);
    output[key] = values.length === 1 ? values[0] : values;
  }
  return output;
}
function queryString(value: Record<string, unknown>): string {
  const query = new URLSearchParams();
  for (const [name, item] of Object.entries(value)) {
    if (Array.isArray(item)) {
      for (const entry of item) query.append(name, String(entry));
    } else if (item !== undefined && item !== null) {
      query.append(
        name,
        typeof item === "object" ? JSON.stringify(item) : String(item),
      );
    }
  }
  return query.toString();
}
function bindRouteValues(
  value: Record<string, unknown>,
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  const output = { ...value };
  for (const [name, item] of Object.entries(params)) {
    if (item !== undefined && name in output) output[name] = item;
  }
  return output;
}
function definedParams(
  params: Record<string, string | undefined>,
): Record<string, string> {
  return Object.fromEntries(
    Object.entries(params).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );
}
function sessionToken(event: RequestEvent): string | undefined {
  return readInternalSession(event)?.opaqueIdentitySessionToken;
}
function csrf(event: RequestEvent): string | undefined {
  return readInternalSession(event)?.csrfToken;
}
function aggregateType(operationId: string): string {
  return (
    operationId
      .replaceAll(/([a-z0-9])([A-Z])/g, "$1_$2")
      .split("_")
      .at(-1)
      ?.toLowerCase() ?? "control"
  );
}
function findAggregateId(
  body: Record<string, unknown>,
  params: Record<string, string | undefined>,
): string {
  for (const [key, value] of [
    ...Object.entries(body),
    ...Object.entries(params),
  ])
    if (key.endsWith("Id") && typeof value === "string") return value;
  return randomUUID();
}
function renderRoute(
  route: string,
  params: Record<string, string | undefined>,
): string {
  return route.replaceAll(
    /\{([^}]+)\}/g,
    (_, key: string) => params[key] ?? "",
  );
}
function normalize(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key.replaceAll(/_([a-z])/g, (_, letter: string) => letter.toUpperCase()),
      item,
    ]),
  );
}
function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
function epochSeconds(value: string): number {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds))
    throw new Error("invalid expiry timestamp");
  return Math.floor(milliseconds / 1000);
}
function stringValue(value: Record<string, unknown>, key: string): string {
  const item = value[key];
  if (typeof item !== "string") throw new Error(`${key} is missing`);
  return item;
}
function problemTitle(value: unknown, status: number): string {
  return isRecord(value) && typeof value.title === "string"
    ? value.title
    : `요청 실패 (${status})`;
}
function stringExtension(
  indexed: IndexedOperation,
  key: `x-${string}`,
): string | undefined {
  const value = indexed.operation[key];
  return typeof value === "string" ? value : undefined;
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function stringProperty(
  value: Record<string, unknown>,
  key: string,
): string | undefined {
  const item = value[key];
  return typeof item === "string" ? item : undefined;
}
function recordProperty(
  value: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const item = value[key];
  return isRecord(item) ? item : {};
}
function isRedirect(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.status === "number" &&
    value.status >= 300 &&
    value.status < 400
  );
}
