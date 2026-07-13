import { randomUUID } from "node:crypto";
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
import { responseRuntimeState } from "$lib/view-models/runtime";
import submissionOpenApi from "../../../../../specs/generated/submission-api.openapi.json";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
} from "./submission-cookie";

const operations = indexOperations([submissionOpenApi as OpenApiDocument]);
export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  const data: Record<string, unknown> = {};
  const errors: string[] = [];
  const session = readSubmissionSession(event);
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET" || !contract.blocking || !session) continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) continue;
    try {
      const result = await invokeSubmissionOperation({
        operationId: contract.operation_id,
        baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
        fetch: serviceAssertionFetch({
          fetch: event.fetch,
          keyBase64: requiredServerValue(
            env,
            "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
          ),
          issuer: "response-portal",
          audience: "submission-api",
          additionalHeaders: {
            "x-gurine-submission-session": session.opaqueSessionToken,
          },
        }),
        path: definedParams(event.params),
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
  const routeValues = {
    ...event.params,
    ...(event.url.searchParams.get("token")
      ? { oneTimeToken: event.url.searchParams.get("token") ?? "" }
      : {}),
  };
  const forms = Object.fromEntries(
    screen.actions.map((action) => {
      const operationId = stringProperty(action, "operation_id");
      const indexed = operationId ? operations.get(operationId) : undefined;
      return [
        action.id,
        indexed
          ? operationFields(
              indexed,
              routeValues,
              recordProperty(action, "preset"),
            )
          : [],
      ];
    }),
  );
  const runtime: ScreenRuntime = {
    state: responseRuntimeState({
      authenticated: Boolean(session),
      errors: errors.length,
      resolved,
    }),
    pathname: event.url.pathname,
    data,
    errors,
    forms,
    ...(session ? { csrfToken: session.csrfToken } : {}),
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
  if (!operationId) throw redirect(303, screen.route);
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
    const routeValues = {
      ...event.params,
      ...(event.url.searchParams.get("token")
        ? { oneTimeToken: event.url.searchParams.get("token") ?? "" }
        : {}),
    };
    const fields = operationFields(
      indexed,
      routeValues,
      recordProperty(action, "preset"),
    );
    const body = normalize(
      formPayload(form, fields, recordProperty(action, "preset")),
    );
    const result = await invokeSubmissionOperation({
      operationId,
      baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
      fetch: serviceAssertionFetch({
        fetch: event.fetch,
        keyBase64: requiredServerValue(
          env,
          "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
        ),
        issuer: "response-portal",
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
    if (!response.ok)
      return fail(response.status, {
        message: problemTitle(value, response.status),
      });
    const rotated = persistSubmissionSession(event, value);
    if (!rotated && operationId === "submitResponse")
      clearSubmissionSessions(event);
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

function renderRoute(
  route: string,
  params: Record<string, string | undefined>,
): string {
  return route.replaceAll(
    /\{([^}]+)\}/g,
    (_, key: string) => params[key] ?? "",
  );
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
