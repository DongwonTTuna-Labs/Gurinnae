import { createHash, randomUUID } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  formPayload,
  indexOperations,
  type OpenApiDocument,
  operationFields,
  optimisticVersion,
  requiredServerValue,
  type SubmissionSessionKind,
  serviceAssertionFetch,
} from "@gurine/config";
import type {
  AttachmentRemovalItem,
  ScreenRuntime,
  ScreenViewModel,
} from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { responseRuntimeState } from "$lib/view-models/runtime";
import submissionOpenApi from "../../../../../specs/generated/submission-api.openapi.json";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
  rotateSubmissionCsrf,
} from "./submission-cookie";

const operations = indexOperations([submissionOpenApi as OpenApiDocument]);
const ATTACHMENT_MAX_BYTES = 52_428_800;
const ATTACHMENT_ACCEPT = [
  "application/pdf",
  "image/jpeg",
  "image/png",
  "text/plain",
  "text/csv",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
].join(",");
export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  const data: Record<string, unknown> = {};
  const errors: string[] = [];
  const session = readSubmissionSession(event);
  const attachmentUpload =
    session?.sessionKind === "RESPONSE_ACTIVE" &&
    hasOperation(screen, "createResponseAttachmentUpload") &&
    hasOperation(screen, "finalizeResponseAttachment");
  const hasOneTimeToken = event.url.searchParams.has("token");
  const oneTimeToken = event.url.searchParams.get("token") ?? "";
  const exchangeContract = screen.dataOperations.find(
    (contract) =>
      contract.blocking &&
      contract.method === "POST" &&
      contract.operation_id.startsWith("exchange"),
  );
  if (hasOneTimeToken && !exchangeContract)
    throw redirect(
      303,
      withoutToken(event.url, "보안 링크를 사용할 수 없습니다."),
    );
  if (hasOneTimeToken && exchangeContract) {
    const indexed = operations.get(exchangeContract.operation_id);
    if (!indexed) {
      throw redirect(
        303,
        withoutToken(
          event.url,
          `${exchangeContract.operation_id} 계약을 찾지 못했습니다.`,
        ),
      );
    } else {
      try {
        const result = await invokeSubmissionOperation({
          operationId: exchangeContract.operation_id,
          baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
          fetch: serviceAssertionFetch({
            fetch: event.fetch,
            keyBase64: requiredServerValue(
              env,
              "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
            ),
            issuer: "response-portal",
            audience: "submission-api",
          }),
          body: { oneTimeToken },
          headers: {
            "Idempotency-Key": randomUUID(),
          },
        });
        const response = result.response ?? new Response(null, { status: 503 });
        const value = isRecord(result.data)
          ? result.data
          : isRecord(result.error)
            ? result.error
            : {};
        if (!response.ok) throw new Error(problemTitle(value, response.status));
        const expectedKinds = sessionKindsForOperation(
          exchangeContract.operation_id,
          value,
        );
        if (
          !expectedKinds ||
          !persistSubmissionSession(event, value, expectedKinds)
        )
          throw new Error("교환 응답에 제출 세션이 없습니다.");
        throw redirect(303, withoutToken(event.url));
      } catch (error) {
        if (isRedirect(error)) throw error;
        throw redirect(
          303,
          withoutToken(
            event.url,
            error instanceof Error
              ? error.message
              : "보안 링크 교환에 실패했습니다.",
          ),
        );
      }
    }
  }
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET" || !session) continue;
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
      if (contract.blocking)
        errors.push(
          error instanceof Error
            ? error.message
            : `${contract.operation_id} 요청 실패`,
        );
    }
  }
  const requiresResponseDraftVersion = screen.actions.some(
    (action) => stringProperty(action, "operation_id") === "submitResponse",
  );
  const requiresAttachmentList =
    session?.sessionKind === "RESPONSE_ACTIVE" &&
    hasOperation(screen, "deleteResponseAttachment");
  if (
    session &&
    data.getResponseDraft === undefined &&
    ((requiresResponseDraftVersion && optimisticVersion(data) === undefined) ||
      requiresAttachmentList)
  ) {
    try {
      data.getResponseDraft = await loadResponseDraft(
        event,
        session.opaqueSessionToken,
      );
      resolved += 1;
    } catch (error) {
      errors.push(
        error instanceof Error
          ? error.message
          : "최신 답변 초안을 확인하지 못했습니다.",
      );
    }
  }
  const responseDraftVersion = optimisticVersion(data.getResponseDraft);
  const responseDraftVersionUnavailable =
    Boolean(session) &&
    requiresResponseDraftVersion &&
    optimisticVersion(data) === undefined &&
    responseDraftVersion === undefined;
  if (
    responseDraftVersionUnavailable &&
    !errors.includes("최신 답변 초안 version을 확인하지 못했습니다.")
  )
    errors.push("최신 답변 초안 version을 확인하지 못했습니다.");
  const responseAttachments =
    requiresAttachmentList && isRecord(data.getResponseDraft)
      ? attachmentItems(data.getResponseDraft)
      : undefined;
  const blockedActionIds = new Set<string>();
  if (responseDraftVersionUnavailable) blockedActionIds.add("submit");
  if (requiresAttachmentList && responseAttachments === undefined)
    for (const action of screen.actions) {
      if (stringProperty(action, "operation_id") === "deleteResponseAttachment")
        blockedActionIds.add(action.id);
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
      const preset = formPreset(
        data,
        recordProperty(action, "preset"),
        responseDraftVersion,
      );
      return [
        action.id,
        indexed ? operationFields(indexed, routeValues, preset) : [],
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
    idempotencyKeys: {
      ...actionIdempotencyKeys(screen),
      ...(attachmentUpload ? { "select-file": randomUUID() } : {}),
    },
    ...(attachmentUpload
      ? {
          attachmentUpload: {
            actionId: "select-file",
            label: "첨부 파일 업로드",
            accept: ATTACHMENT_ACCEPT,
            maxBytes: ATTACHMENT_MAX_BYTES,
          },
        }
      : {}),
    ...(responseAttachments
      ? {
          attachmentRemoval: {
            actionId: "remove-file",
            label: "파일 제거",
            items: responseAttachments,
          },
        }
      : {}),
    ...(blockedActionIds.size > 0
      ? {
          allowedActionIds: screen.actions
            .filter((action) => !blockedActionIds.has(action.id))
            .map((action) => action.id),
        }
      : {}),
    ...(session ? { csrfToken: session.csrfToken } : {}),
    ...(event.url.searchParams.get("notice")
      ? { notice: event.url.searchParams.get("notice") ?? "" }
      : {}),
  };
  return { screen, runtime };
}

export function screenActions(screen: ScreenViewModel): Actions {
  const actions: Actions = Object.fromEntries(
    screen.actions.map((action) => [
      action.id,
      async (event: RequestEvent) => runAction(event, screen, action),
    ]),
  );
  if (
    hasOperation(screen, "createResponseAttachmentUpload") &&
    hasOperation(screen, "finalizeResponseAttachment")
  )
    actions["select-file"] = (event: RequestEvent) =>
      uploadResponseAttachment(event);
  return actions;
}

async function uploadResponseAttachment(event: RequestEvent) {
  try {
    const form = await event.request.formData();
    const session = readSubmissionSession(event);
    if (session?.sessionKind !== "RESPONSE_ACTIVE")
      return fail(401, { message: "활성 소명 제출 세션이 필요합니다." });
    if (form.get("csrfToken") !== session.csrfToken)
      return fail(403, { message: "CSRF_TOKEN_STALE" });
    const idempotencyKey = formIdempotencyKey(form);
    const file = form.get("attachment");
    if (!(file instanceof File) || file.size < 1)
      return fail(400, { message: "업로드할 파일을 선택해 주세요." });
    if (file.size > ATTACHMENT_MAX_BYTES)
      return fail(413, { message: "첨부 파일은 50 MiB를 초과할 수 없습니다." });
    const filename = safeFilename(file.name);
    const mediaType = attachmentMediaType(file);
    if (!mediaType)
      return fail(415, { message: "지원하지 않는 첨부 파일 형식입니다." });
    const bytes = new Uint8Array(await file.arrayBuffer());
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const created = await invokeSessionOperation(
      event,
      session.opaqueSessionToken,
      "createResponseAttachmentUpload",
      { filename, mediaType, sizeBytes: bytes.byteLength, sha256 },
      `${idempotencyKey}:create`,
    );
    if (!created.response.ok)
      return fail(created.response.status, {
        message: problemTitle(created.value, created.response.status),
      });
    const attachmentId = uuidProperty(created.value, "aggregateId");
    if (!attachmentId)
      return fail(502, { message: "첨부 식별자를 받지 못했습니다." });
    const uploaded = await uploadAttachmentBytes(
      event,
      attachmentId,
      bytes,
      session.opaqueSessionToken,
    );
    if (!uploaded.ok)
      return fail(uploaded.status, {
        message: `첨부 파일 전송에 실패했습니다. (${uploaded.status})`,
      });
    const finalized = await invokeSessionOperation(
      event,
      session.opaqueSessionToken,
      "finalizeResponseAttachment",
      {
        objectEtag: uploaded.headers.get("etag") ?? sha256,
        uploadedSizeBytes: bytes.byteLength,
        uploadedSha256: sha256,
      },
      `${idempotencyKey}:finalize`,
      { attachmentId },
    );
    if (!finalized.response.ok)
      return fail(finalized.response.status, {
        message: problemTitle(finalized.value, finalized.response.status),
      });
    rotateSubmissionCsrf(event);
    throw redirect(
      303,
      `${event.url.pathname}?notice=${encodeURIComponent("첨부 파일을 격리 저장소에 전송했으며 검사를 시작했습니다.")}`,
    );
  } catch (error) {
    if (isRedirect(error)) throw error;
    return fail(400, {
      message:
        error instanceof Error
          ? error.message
          : "첨부 파일을 처리하지 못했습니다.",
    });
  }
}

async function invokeSessionOperation(
  event: RequestEvent,
  sessionToken: string,
  operationId: string,
  body: Record<string, unknown>,
  idempotencyKey: string,
  path: Record<string, unknown> = definedParams(event.params),
) {
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
      additionalHeaders: {
        "x-gurine-submission-session": sessionToken,
      },
    }),
    path,
    body,
    headers: { "Idempotency-Key": idempotencyKey },
  });
  return {
    response: result.response ?? new Response(null, { status: 503 }),
    value: isRecord(result.data)
      ? result.data
      : isRecord(result.error)
        ? result.error
        : {},
  };
}

async function uploadAttachmentBytes(
  event: RequestEvent,
  attachmentId: string,
  bytes: Uint8Array<ArrayBuffer>,
  sessionToken: string,
): Promise<Response> {
  const baseUrl = requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL");
  const signedFetch = serviceAssertionFetch({
    fetch: event.fetch,
    keyBase64: requiredServerValue(
      env,
      "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
    ),
    issuer: "response-portal",
    audience: "submission-api",
    additionalHeaders: {
      "x-gurine-submission-session": sessionToken,
    },
  });
  return signedFetch(
    new URL(
      `/internal/submission-uploads/${encodeURIComponent(attachmentId)}`,
      baseUrl,
    ),
    {
      method: "PUT",
      headers: { "content-type": "application/octet-stream" },
      body: bytes,
    },
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
    const idempotencyKey = formIdempotencyKey(form);
    const path = operationFormPathParams(indexed.path, event.params, form);
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
    const body = bindRouteValues(
      normalize(formPayload(form, fields, recordProperty(action, "preset"))),
      event.params,
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
      path,
      body,
      headers: { "Idempotency-Key": idempotencyKey },
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
    const expectedKinds = sessionKindsForOperation(operationId, value);
    if (operationId === "verifyResponseAccess" && !expectedKinds) {
      clearSubmissionSessions(event);
      return fail(502, { message: "인증 응답 상태가 올바르지 않습니다." });
    }
    const rotated = expectedKinds
      ? persistSubmissionSession(event, value, expectedKinds)
      : false;
    if (expectedKinds && !rotated) {
      clearSubmissionSessions(event);
      return fail(502, { message: "후속 제출 세션을 만들지 못했습니다." });
    }
    if (
      operationId === "verifyResponseAccess" &&
      value.status === "VERIFICATION_FAILED"
    ) {
      const remaining =
        typeof value.remainingAttempts === "number"
          ? value.remainingAttempts
          : 0;
      return fail(422, {
        message: `인증번호가 올바르지 않습니다. 남은 시도 횟수: ${remaining}`,
      });
    }
    if (!rotated && session) rotateSubmissionCsrf(event);
    const destination =
      operationId === "submitResponse"
        ? "/respond/receipt"
        : renderRoute(screen.route, event.params);
    throw redirect(
      303,
      `${destination}?notice=${encodeURIComponent(`${action.label} 완료`)}`,
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
function withoutToken(url: URL, notice?: string): string {
  const clean = new URL(url);
  clean.searchParams.delete("token");
  if (notice) clean.searchParams.set("notice", notice);
  return `${clean.pathname}${clean.search}${clean.hash}`;
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
function operationFormPathParams(
  path: string,
  params: Record<string, string | undefined>,
  form: FormData,
): Record<string, unknown> {
  const output = definedParams(params);
  for (const match of path.matchAll(/\{([^}]+)\}/g)) {
    const name = match[1];
    if (!name || output[name] !== undefined) continue;
    const value = form.get(name);
    if (typeof value !== "string" || value.length < 1 || value.length > 200)
      throw new Error(`${name} 경로 값이 필요합니다.`);
    if (name.endsWith("Id") && !isUuid(value))
      throw new Error(`${name} 경로 값이 올바르지 않습니다.`);
    output[name] = value;
  }
  return output;
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
function actionIdempotencyKeys(
  screen: ScreenViewModel,
): Readonly<Record<string, string>> {
  return Object.fromEntries(
    screen.actions
      .filter((action) => stringProperty(action, "operation_id"))
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
function sessionKindsForOperation(
  operationId: string,
  value: Record<string, unknown>,
): readonly SubmissionSessionKind[] | undefined {
  switch (operationId) {
    case "exchangeResponseAccessToken":
      return ["RESPONSE_PENDING"];
    case "verifyResponseAccess":
      if (value.status === "VERIFIED") return ["RESPONSE_ACTIVE"];
      if (value.status === "VERIFICATION_FAILED") return ["RESPONSE_PENDING"];
      return undefined;
    case "submitResponse":
    case "exchangeResponseReceiptToken":
      return ["RESPONSE_RECEIPT"];
    default:
      return undefined;
  }
}
function formPreset(
  data: Record<string, unknown>,
  explicit: Record<string, unknown>,
  expectedVersionFallback?: number,
): Record<string, unknown> {
  const expectedVersion = optimisticVersion(data) ?? expectedVersionFallback;
  return {
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    ...explicit,
  };
}
async function loadResponseDraft(
  event: RequestEvent,
  sessionToken: string,
): Promise<Record<string, unknown>> {
  if (!operations.has("getResponseDraft"))
    throw new Error("getResponseDraft 계약을 찾지 못했습니다.");
  const result = await invokeSubmissionOperation({
    operationId: "getResponseDraft",
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
        "x-gurine-submission-session": sessionToken,
      },
    }),
    path: definedParams(event.params),
  });
  if (!result.response?.ok)
    throw new Error(problemTitle(result.error, result.response?.status ?? 503));
  if (!isRecord(result.data))
    throw new Error("최신 답변 초안 응답이 올바르지 않습니다.");
  return result.data;
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
function uuidProperty(
  value: Record<string, unknown>,
  key: string,
): string | undefined {
  const item = value[key];
  return typeof item === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      item,
    )
    ? item
    : undefined;
}
function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}
function attachmentItems(
  value: Record<string, unknown>,
): AttachmentRemovalItem[] {
  const attachments = value.attachments;
  if (!Array.isArray(attachments)) return [];
  return attachments.flatMap((item) => {
    if (!isRecord(item)) return [];
    const id = stringProperty(item, "id");
    if (!id || !isUuid(id)) return [];
    const filename = stringProperty(item, "filename")?.trim();
    const mediaType = stringProperty(item, "mediaType");
    const uploadStatus = stringProperty(item, "uploadStatus");
    const scanStatus = stringProperty(item, "scanStatus");
    const sizeBytes = item.sizeBytes;
    return [
      {
        id,
        filename:
          filename && filename.length <= 255
            ? filename
            : `첨부 파일 ${id.slice(0, 8)}`,
        ...(mediaType ? { mediaType } : {}),
        ...(typeof sizeBytes === "number" && Number.isSafeInteger(sizeBytes)
          ? { sizeBytes }
          : {}),
        ...(uploadStatus ? { uploadStatus } : {}),
        ...(scanStatus ? { scanStatus } : {}),
      },
    ];
  });
}
function hasOperation(screen: ScreenViewModel, operationId: string): boolean {
  return screen.dataOperations.some(
    (operation) => operation.operation_id === operationId,
  );
}
function safeFilename(value: string): string {
  const name = value.split(/[\\/]/).at(-1)?.trim() ?? "";
  if (
    name.length < 1 ||
    name.length > 255 ||
    [...name].some((character) => {
      const code = character.codePointAt(0) ?? 0;
      return code <= 31 || code === 127;
    })
  )
    throw new Error("첨부 파일 이름이 올바르지 않습니다.");
  return name;
}
function attachmentMediaType(file: File): string | undefined {
  const declared = file.type.trim().toLowerCase();
  if (ATTACHMENT_ACCEPT.split(",").includes(declared)) return declared;
  const extension = file.name.split(".").at(-1)?.toLowerCase();
  return {
    pdf: "application/pdf",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    png: "image/png",
    txt: "text/plain",
    csv: "text/csv",
    docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  }[extension ?? ""];
}
function isRedirect(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.status === "number" &&
    value.status >= 300 &&
    value.status < 400
  );
}
