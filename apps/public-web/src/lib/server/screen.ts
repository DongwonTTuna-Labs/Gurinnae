import { randomUUID } from "node:crypto";
import { invokePublicOperation } from "@gurine/api-client-public";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  formPayload,
  indexOperations,
  type OpenApiDocument,
  operationFields,
  requiredServerValue,
  serviceAssertionFetch,
} from "@gurine/config";
import type { ScreenRuntime, ScreenViewModel } from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { publicRuntimeState } from "$lib/view-models/runtime";
import publicOpenApi from "../../../../../specs/generated/public-api.openapi.json";
import submissionOpenApi from "../../../../../specs/generated/submission-api.openapi.json";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
} from "./submission-cookie";

const operations = indexOperations([
  publicOpenApi as OpenApiDocument,
  submissionOpenApi as OpenApiDocument,
]);
export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  const data: Record<string, unknown> = {};
  const errors: string[] = [];
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET" || !contract.blocking) continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) {
      errors.push(`${contract.operation_id} 계약을 찾지 못했습니다.`);
      continue;
    }
    try {
      const query = operationQuery(
        indexed.operation.parameters ?? [],
        event.url.searchParams,
      );
      if (query === null) {
        data[contract.operation_id] = {
          items: [],
          appliedFilters: {},
          asOf: new Date().toISOString(),
        };
        continue;
      }
      const result = await invokePublicOperation({
        operationId: contract.operation_id,
        baseUrl: requiredServerValue(env, "PUBLIC_API_INTERNAL_URL"),
        fetch: event.fetch,
        path: operationPathParams(indexed.path, event.params),
        query,
      });
      if (!result.response?.ok)
        throw new Error(
          problemTitle(result.error, result.response?.status ?? 503),
        );
      data[contract.operation_id] = result.data;
      resolved += 1;
    } catch (error) {
      errors.push(
        error instanceof Error
          ? error.message
          : `${contract.operation_id} 요청 실패`,
      );
    }
  }
  const forms = Object.fromEntries(
    screen.actions.map((action) => {
      const operationId = stringProperty(action, "operation_id");
      const indexed = operationId ? operations.get(operationId) : undefined;
      return [
        action.id,
        indexed
          ? operationFields(
              indexed,
              event.params,
              recordProperty(action, "preset"),
            )
          : [],
      ];
    }),
  );
  const hasData = Object.values(data).some((value) => hasRecords(value));
  const submissionSession = readSubmissionSession(event);
  const runtime: ScreenRuntime = {
    state: publicRuntimeState({ errors: errors.length, resolved, hasData }),
    pathname: event.url.pathname,
    data,
    errors,
    forms,
    ...(submissionSession ? { csrfToken: submissionSession.csrfToken } : {}),
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
  if (!operationId) {
    throw redirect(
      303,
      `${event.url.pathname}?notice=${encodeURIComponent(`${action.label} 작업을 적용했습니다.`)}`,
    );
  }
  const indexed = operations.get(operationId);
  if (!indexed) return fail(500, { message: "operation contract missing" });
  try {
    const form = await event.request.formData();
    const session = readSubmissionSession(event);
    if (session) {
      if (form.get("csrfToken") !== session.csrfToken)
        return fail(403, { message: "CSRF_TOKEN_STALE" });
    } else if (!sameOrigin(event)) {
      return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    }
    const fields = operationFields(
      indexed,
      event.params,
      recordProperty(action, "preset"),
    );
    const payload = normalize(
      formPayload(form, fields, recordProperty(action, "preset")),
    );
    if (indexed.operation["x-operation-kind"] !== "COMMAND") {
      throw new Error("읽기 operation은 form action으로 실행할 수 없습니다.");
    }
    const { response, value } = await submissionRequest(
      event,
      operationId,
      payload,
    );
    if (!response.ok)
      return fail(response.status, {
        message: problemTitle(value, response.status),
      });
    const rotated = persistSubmissionSession(event, value);
    if (
      !rotated &&
      ["deleteCorrectionRequestDraft", "unsubscribe"].includes(operationId)
    ) {
      clearSubmissionSessions(event);
    }
    throw redirect(
      303,
      `${renderRoute(screen.route, event.params)}?notice=${encodeURIComponent(`${action.label} 완료`)}`,
    );
  } catch (error) {
    if (isRedirect(error)) throw error;
    return fail(400, {
      message:
        error instanceof Error ? error.message : "요청을 처리하지 못했습니다.",
    });
  }
}

async function submissionRequest(
  event: RequestEvent,
  operationId: string,
  body: Record<string, unknown>,
) {
  const key = requiredServerValue(
    env,
    "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT",
  );
  const baseUrl = requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL");
  const session = readSubmissionSession(event);
  const result = await invokeSubmissionOperation({
    operationId,
    baseUrl,
    fetch: serviceAssertionFetch({
      fetch: event.fetch,
      keyBase64: key,
      issuer: "public-web",
      audience: "submission-api",
      ...(session
        ? {
            additionalHeaders: {
              "x-gurine-submission-session": session.opaqueSessionToken,
            },
          }
        : {}),
    }),
    path: definedParams(event.params),
    body,
    headers: { "Idempotency-Key": randomUUID() },
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  if (session && response.status === 401) clearSubmissionSessions(event);
  return { response, value };
}

function operationQuery(
  parameters: Array<{ name: string; in: string; required?: boolean }>,
  current: URLSearchParams,
): Record<string, unknown> | null {
  const query: Record<string, unknown> = {};
  for (const parameter of parameters.filter((item) => item.in === "query")) {
    const values = current.getAll(parameter.name);
    if (values.length === 0 && parameter.required) return null;
    if (values.length === 1) query[parameter.name] = values[0];
    else if (values.length > 1) query[parameter.name] = values;
  }
  return query;
}

function definedParams(
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(params).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );
}

function operationPathParams(
  path: string,
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  const output = definedParams(params);
  for (const match of path.matchAll(/\{([^}]+)\}/g)) {
    const name = match[1];
    if (!name || output[name] !== undefined) continue;
    const slugAlias = name.endsWith("Id") ? `${name.slice(0, -2)}Slug` : name;
    const value = params[slugAlias];
    if (value !== undefined) output[name] = value;
  }
  return output;
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
function sameOrigin(event: RequestEvent): boolean {
  const origin = event.request.headers.get("origin");
  const fetchSite = event.request.headers.get("sec-fetch-site");
  return (
    origin === event.url.origin && (!fetchSite || fetchSite === "same-origin")
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

function problemTitle(value: unknown, status: number): string {
  return isRecord(value) && typeof value.title === "string"
    ? value.title
    : `요청 실패 (${status})`;
}
function hasRecords(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return !Array.isArray(value.items) || value.items.length > 0;
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
