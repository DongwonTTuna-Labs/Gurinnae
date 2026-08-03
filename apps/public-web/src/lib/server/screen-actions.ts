import { createHash } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  bindSyntheticAbuseProof,
  formPayload,
  isSubmissionSessionDescriptor,
  operationFields,
  requiredServerValue,
  serviceAssertionFetch,
} from "@gurine/config";
import type { ScreenViewModel } from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { ATTACHMENT_MAX_BYTES, operations } from "./screen-contract";
import {
  actionOperationId,
  actionPreset,
  attachmentMediaType,
  bindRouteValues,
  checkAnonymousRateLimit,
  correctionBootstrapFields,
  correctionBootstrapRequired,
  formIdempotencyKey,
  hasOperation,
  isRecord,
  isRedirect,
  isUuid,
  normalize,
  problemTitle,
  renderRoute,
  safeFilename,
  sameOrigin,
  sessionKindsForOperation,
  stableIdempotencyKey,
  uuidProperty,
} from "./screen-helpers";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
  rotateSubmissionCsrf,
} from "./submission-cookie";

export function screenActions(screen: ScreenViewModel): Actions {
  const actions: Actions = Object.fromEntries(
    screen.actions.map((action) => [
      action.id,
      async (event: RequestEvent) => runAction(event, screen, action),
    ]),
  );
  if (
    hasOperation(screen, "createCorrectionAttachment") &&
    hasOperation(screen, "finalizeCorrectionAttachment")
  )
    actions["upload-attachment"] = (event: RequestEvent) =>
      uploadCorrectionAttachment(event);
  if (hasOperation(screen, "deleteCorrectionAttachment"))
    actions["remove-attachment"] = (event: RequestEvent) =>
      runAction(event, screen, {
        id: "remove-attachment",
        label: "첨부 파일 제거",
        operation_id: "deleteCorrectionAttachment",
      });
  return actions;
}

async function uploadCorrectionAttachment(event: RequestEvent) {
  try {
    const form = await event.request.formData();
    const session = readSubmissionSession(event);
    if (session?.sessionKind !== "CORRECTION_DRAFT")
      return fail(401, { message: "정정 초안 제출 세션이 필요합니다." });
    if (!sameOrigin(event)) return fail(403, { message: "CSRF_ORIGIN_DENIED" });
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
    const created = await submissionRequest(
      event,
      "createCorrectionAttachment",
      { filename, mediaType, sizeBytes: bytes.byteLength, sha256 },
      session.opaqueSessionToken,
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
    const finalized = await submissionRequest(
      event,
      "finalizeCorrectionAttachment",
      {
        objectEtag: uploaded.headers.get("etag") ?? sha256,
        uploadedSizeBytes: bytes.byteLength,
        uploadedSha256: sha256,
      },
      session.opaqueSessionToken,
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

async function runAction(
  event: RequestEvent,
  screen: ScreenViewModel,
  action: ScreenViewModel["actions"][number],
) {
  const operationId = actionOperationId(screen, action);
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
      if (!sameOrigin(event))
        return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    } else if (!sameOrigin(event)) {
      return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    }
    const idempotencyKey = formIdempotencyKey(form);
    const pathOverrides = operationFormPathParams(
      indexed.path,
      event.params,
      form,
    );
    const preset = actionPreset(event, screen, action);
    const fields = operationFields(indexed, event.params, preset);
    const payload = bindRouteValues(
      {
        ...normalize(formPayload(form, fields, preset)),
        ...normalize(preset),
      },
      event.params,
    );
    if (indexed.operation["x-operation-kind"] !== "COMMAND") {
      throw new Error("읽기 operation은 form action으로 실행할 수 없습니다.");
    }
    let createdSessionToken: string | undefined;
    if (correctionBootstrapRequired(screen, session)) {
      if (operationId !== "saveCorrectionRequestDraft")
        return fail(409, { message: "먼저 정정 요청 초안을 저장해 주세요." });
      const createFields = correctionBootstrapFields(event);
      const createPayload = normalize(formPayload(form, createFields));
      const rateLimitFailure = checkAnonymousRateLimit(
        event,
        "createCorrectionRequestDraft",
        createPayload,
      );
      if (rateLimitFailure)
        return fail(rateLimitFailure.status, {
          message: rateLimitFailure.message,
        });
      const created = await submissionRequest(
        event,
        "createCorrectionRequestDraft",
        createPayload,
        undefined,
        idempotencyKey,
      );
      if (!created.response.ok)
        return fail(created.response.status, {
          message: problemTitle(created.value, created.response.status),
        });
      const descriptor = created.value.session;
      if (
        !isSubmissionSessionDescriptor(descriptor) ||
        descriptor.sessionKind !== "CORRECTION_DRAFT" ||
        !persistSubmissionSession(event, created.value, ["CORRECTION_DRAFT"])
      )
        return fail(502, {
          message: "정정 요청 제출 세션을 만들지 못했습니다.",
        });
      createdSessionToken = descriptor.opaqueSessionToken;
    }
    const rateLimitFailure = checkAnonymousRateLimit(
      event,
      operationId,
      payload,
    );
    if (rateLimitFailure)
      return fail(rateLimitFailure.status, {
        message: rateLimitFailure.message,
      });
    const { response, value } = await submissionRequest(
      event,
      operationId,
      payload,
      createdSessionToken,
      idempotencyKey,
      pathOverrides,
    );
    if (!response.ok)
      return fail(response.status, {
        message: problemTitle(value, response.status),
      });
    const expectedKinds = sessionKindsForOperation(operationId);
    const rotated = expectedKinds
      ? persistSubmissionSession(event, value, expectedKinds)
      : false;
    if (expectedKinds && !rotated) {
      clearSubmissionSessions(event);
      return fail(502, { message: "후속 제출 세션을 만들지 못했습니다." });
    }
    if (
      !rotated &&
      ["deleteCorrectionRequestDraft", "unsubscribe"].includes(operationId)
    ) {
      clearSubmissionSessions(event);
    } else if (!rotated && session) rotateSubmissionCsrf(event);
    const destination =
      operationId === "createCorrectionRequest"
        ? "/correction-request/receipt"
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

export async function submissionRequest(
  event: RequestEvent,
  operationId: string,
  body: Record<string, unknown>,
  sessionToken?: string,
  idempotencyKey: string = stableIdempotencyKey(operationId, body),
  pathOverrides: Record<string, unknown> = {},
) {
  const key = requiredServerValue(
    env,
    "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT",
  );
  const boundBody = bindSyntheticAbuseProof(body, {
    action: operationId,
    keyBase64: key,
    siteKey: env.BOT_CHALLENGE_SITE_KEY?.trim(),
  });
  const baseUrl = requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL");
  const session = readSubmissionSession(event);
  const opaqueSessionToken = sessionToken ?? session?.opaqueSessionToken;
  const result = await invokeSubmissionOperation({
    operationId,
    baseUrl,
    fetch: serviceAssertionFetch({
      fetch: event.fetch,
      keyBase64: key,
      issuer: "public-web",
      audience: "submission-api",
      ...(opaqueSessionToken
        ? {
            additionalHeaders: {
              "x-gurine-submission-session": opaqueSessionToken,
            },
          }
        : {}),
    }),
    path: { ...definedParams(event.params), ...pathOverrides },
    body: boundBody,
    headers: { "Idempotency-Key": idempotencyKey },
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  if (opaqueSessionToken && response.status === 401)
    clearSubmissionSessions(event);
  return { response, value };
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
      "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT",
    ),
    issuer: "public-web",
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

export async function submissionLoadRequest(
  event: RequestEvent,
  operationId: string,
  path: string,
  query: Record<string, unknown>,
  session: ReturnType<typeof readSubmissionSession>,
) {
  if (!session) throw new Error("제출 세션이 필요합니다.");
  return invokeSubmissionOperation({
    operationId,
    baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
    fetch: serviceAssertionFetch({
      fetch: event.fetch,
      keyBase64: requiredServerValue(
        env,
        "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT",
      ),
      issuer: "public-web",
      audience: "submission-api",
      additionalHeaders: {
        "x-gurine-submission-session": session.opaqueSessionToken,
      },
    }),
    path: operationPathParams(path, event.params),
    query,
  });
}

export function operationQuery(
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

export function operationPathParams(
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

function operationFormPathParams(
  path: string,
  params: Record<string, string | undefined>,
  form: FormData,
): Record<string, unknown> {
  const output = operationPathParams(path, params);
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
