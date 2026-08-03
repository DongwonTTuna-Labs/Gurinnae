import { createHash, timingSafeEqual } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  formPayload,
  operationFields,
  requiredServerValue,
  serviceAssertionFetch,
} from "@gurine/config";
import type { ScreenViewModel } from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { ATTACHMENT_MAX_BYTES, operations } from "./screen-contract";
import {
  attachmentMediaType,
  bindRouteValues,
  definedParams,
  formIdempotencyKey,
  hasOperation,
  isRecord,
  isRedirect,
  normalize,
  operationFormPathParams,
  problemTitle,
  recordProperty,
  renderRoute,
  safeFilename,
  sameOrigin,
  sessionKindsForOperation,
  stringProperty,
  uuidProperty,
} from "./screen-helpers";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
  rotateSubmissionCsrf,
} from "./submission-cookie";

function csrfMatches(
  candidate: FormDataEntryValue | null,
  expected: string,
): boolean {
  if (typeof candidate !== "string") return false;
  const actual = Buffer.from(candidate, "utf8");
  const target = Buffer.from(expected, "utf8");
  return actual.length === target.length && timingSafeEqual(actual, target);
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
    if (!sameOrigin(event)) return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    if (!csrfMatches(form.get("csrfToken"), session.csrfToken))
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
  if (!indexed) return fail(500, { message: "작업 계약을 찾지 못했습니다." });
  let submittedFormData: Record<string, unknown> = {};
  try {
    const form = await event.request.formData();
    const session = readSubmissionSession(event);
    if (session) {
      if (!sameOrigin(event))
        return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    } else if (!sameOrigin(event)) {
      return fail(403, { message: "CSRF_ORIGIN_DENIED" });
    }
    if (!session || !csrfMatches(form.get("csrfToken"), session.csrfToken))
      return fail(403, { message: "CSRF_TOKEN_STALE" });
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
    submittedFormData = body;
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
        formData: submittedFormData,
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
      formData: submittedFormData,
    });
  }
}
