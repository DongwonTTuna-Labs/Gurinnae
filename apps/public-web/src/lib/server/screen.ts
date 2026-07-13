import { createHash, randomUUID } from "node:crypto";
import { invokePublicOperation } from "@gurine/api-client-public";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  formPayload,
  indexOperations,
  isSubmissionSessionDescriptor,
  type OpenApiDocument,
  operationFields,
  optimisticVersion,
  requiredServerValue,
  type SubmissionSessionKind,
  serviceAssertionFetch,
} from "@gurine/config";
import type {
  AttachmentRemovalItem,
  ScreenField,
  ScreenRuntime,
  ScreenViewModel,
} from "@gurine/ui";
import { type Actions, fail, type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { publicRuntimeState } from "$lib/view-models/runtime";
import publicOpenApi from "../../../../../specs/generated/public-api.openapi.json";
import submissionOpenApi from "../../../../../specs/generated/submission-api.openapi.json";
import {
  anonymousDestination,
  anonymousSubmissionRateLimiter,
  isAnonymousSubmissionOperation,
} from "./anonymous-rate-limit";
import {
  clearSubmissionSessions,
  persistSubmissionSession,
  readSubmissionSession,
  rotateSubmissionCsrf,
} from "./submission-cookie";
import { subscriptionPreset } from "./subscription-preset";

const operations = indexOperations([
  publicOpenApi as OpenApiDocument,
  submissionOpenApi as OpenApiDocument,
]);
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
  const submissionSession = readSubmissionSession(event);
  const attachmentUpload =
    submissionSession?.sessionKind === "CORRECTION_DRAFT" &&
    hasOperation(screen, "createCorrectionAttachment") &&
    hasOperation(screen, "finalizeCorrectionAttachment");
  const bootstrapCorrection = correctionBootstrapRequired(
    screen,
    submissionSession,
  );
  const hasOneTimeToken = event.url.searchParams.has("token");
  const oneTimeToken = event.url.searchParams.get("token") ?? "";
  const tokenContract = screen.dataOperations.find(
    (contract) =>
      contract.blocking &&
      contract.method === "POST" &&
      (contract.operation_id.startsWith("exchange") ||
        contract.operation_id === "verifySubscription"),
  );
  if (hasOneTimeToken && !tokenContract)
    throw redirect(
      303,
      withoutToken(event.url, "보안 링크를 사용할 수 없습니다."),
    );
  if (hasOneTimeToken && tokenContract) {
    try {
      const { response, value } = await submissionRequest(
        event,
        tokenContract.operation_id,
        tokenBody(tokenContract.operation_id, oneTimeToken),
      );
      if (!response.ok) throw new Error(problemTitle(value, response.status));
      const expectedKinds = sessionKindsForOperation(
        tokenContract.operation_id,
      );
      if (
        !expectedKinds ||
        !persistSubmissionSession(event, value, expectedKinds)
      )
        throw new Error("교환 응답에 제출 세션이 없습니다.");
      throw redirect(
        303,
        tokenDestination(event.url, tokenContract.operation_id),
      );
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
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET") continue;
    if (bootstrapCorrection && contract.api === "submission-api") continue;
    if (!contract.blocking && contract.operation_id.startsWith("download"))
      continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) {
      if (contract.blocking)
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
      const result =
        contract.api === "submission-api"
          ? await submissionLoadRequest(
              event,
              contract.operation_id,
              indexed.path,
              query,
              submissionSession,
            )
          : await invokePublicOperation({
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
      if (contract.blocking)
        errors.push(
          error instanceof Error
            ? error.message
            : `${contract.operation_id} 요청 실패`,
        );
    }
  }
  const correctionAttachments =
    submissionSession?.sessionKind === "CORRECTION_DRAFT" &&
    hasOperation(screen, "deleteCorrectionAttachment") &&
    isRecord(data.getCorrectionRequestDraftPreview)
      ? attachmentItems(data.getCorrectionRequestDraftPreview)
      : undefined;
  const forms: Record<string, readonly ScreenField[]> = Object.fromEntries(
    screen.actions.map((action) => {
      const operationId = actionOperationId(screen, action);
      const indexed = operationId ? operations.get(operationId) : undefined;
      const preset = formPreset(data, actionPreset(event, screen, action));
      const fields = indexed
        ? operationFields(indexed, event.params, preset)
        : [];
      return [
        action.id,
        bootstrapCorrection && operationId === "saveCorrectionRequestDraft"
          ? mergeFields(correctionBootstrapFields(event), fields)
          : fields,
      ];
    }),
  );
  const needsBotChallenge = Object.values(forms).some((fields) =>
    fields.some((field) => field.name === "abuseProof"),
  );
  const siteKey = env.BOT_CHALLENGE_SITE_KEY?.trim();
  if (needsBotChallenge && !siteKey)
    errors.push("자동 제출 방지 검증이 구성되지 않았습니다.");
  const hasData = Object.values(data).some((value) => hasRecords(value));
  const runtime: ScreenRuntime = {
    state: publicRuntimeState({ errors: errors.length, resolved, hasData }),
    pathname: event.url.pathname,
    data,
    errors,
    forms,
    ...(screen.id === "PUB-020"
      ? { formOperationIds: { "download-dataset": "createDatasetExport" } }
      : {}),
    idempotencyKeys: {
      ...actionIdempotencyKeys(screen),
      ...(attachmentUpload ? { "upload-attachment": randomUUID() } : {}),
      ...(correctionAttachments ? { "remove-attachment": randomUUID() } : {}),
    },
    ...(needsBotChallenge && siteKey
      ? {
          botChallenge: {
            provider:
              siteKey === "synthetic-test" ? "SYNTHETIC_TEST" : "TURNSTILE",
            siteKey,
          } as const,
        }
      : {}),
    ...(attachmentUpload
      ? {
          attachmentUpload: {
            actionId: "upload-attachment",
            label: "근거 파일 업로드",
            accept: ATTACHMENT_ACCEPT,
            maxBytes: ATTACHMENT_MAX_BYTES,
          },
        }
      : {}),
    ...(correctionAttachments
      ? {
          attachmentRemoval: {
            actionId: "remove-attachment",
            label: "첨부 파일 제거",
            items: correctionAttachments,
          },
        }
      : {}),
    ...(bootstrapCorrection ? { allowedActionIds: ["save-draft"] } : {}),
    ...(submissionSession ? { csrfToken: submissionSession.csrfToken } : {}),
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
      if (form.get("csrfToken") !== session.csrfToken)
        return fail(403, { message: "CSRF_TOKEN_STALE" });
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

async function submissionRequest(
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
    body,
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

async function submissionLoadRequest(
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
function tokenBody(
  operationId: string,
  token: string,
): Record<string, unknown> {
  return operationId === "verifySubscription"
    ? { verificationToken: token }
    : { oneTimeToken: token };
}
function tokenDestination(url: URL, operationId: string): string {
  if (operationId !== "verifySubscription") return withoutToken(url);
  const destination = new URL("/subscription/manage", url);
  return withoutToken(destination, "구독 이메일 검증을 완료했습니다.");
}
function sessionKindsForOperation(
  operationId: string,
): readonly SubmissionSessionKind[] | undefined {
  switch (operationId) {
    case "createCorrectionRequestDraft":
      return ["CORRECTION_DRAFT"];
    case "createCorrectionRequest":
    case "exchangeCorrectionReceiptToken":
      return ["CORRECTION_RECEIPT"];
    case "createSubscription":
      return ["SUBSCRIPTION_PENDING"];
    case "verifySubscription":
    case "exchangeSubscriptionManagementToken":
      return ["SUBSCRIPTION_MANAGEMENT"];
    default:
      return undefined;
  }
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
      .filter((action) => actionOperationId(screen, action))
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

function stableIdempotencyKey(
  operationId: string,
  body: Record<string, unknown>,
): string {
  return createHash("sha256")
    .update(JSON.stringify([operationId, body]))
    .digest("hex");
}

function correctionBootstrapRequired(
  screen: ScreenViewModel,
  session: ReturnType<typeof readSubmissionSession>,
): boolean {
  return (
    !session &&
    screen.dataOperations.some(
      (contract) => contract.operation_id === "createCorrectionRequestDraft",
    )
  );
}

function correctionBootstrapFields(event: RequestEvent): ScreenField[] {
  const indexed = operations.get("createCorrectionRequestDraft");
  if (!indexed)
    throw new Error("createCorrectionRequestDraft contract missing");
  const locale =
    event.request.headers.get("accept-language")?.split(",", 1)[0]?.trim() ||
    "ko-KR";
  const caseSlug =
    event.url.searchParams.get("caseSlug") ??
    event.url.searchParams.get("case") ??
    undefined;
  const revisionText =
    event.url.searchParams.get("publicationRevision") ??
    event.url.searchParams.get("revision");
  const publicationRevision =
    revisionText && /^\d+$/.test(revisionText)
      ? Number.parseInt(revisionText, 10)
      : undefined;
  return operationFields(indexed, event.params, {
    locale,
    ...(caseSlug ? { caseSlug } : {}),
    ...(publicationRevision !== undefined ? { publicationRevision } : {}),
  }).map((field) =>
    field.name === "abuseProof"
      ? { ...field, challengeAction: "createCorrectionRequestDraft" }
      : field,
  );
}

function mergeFields(
  first: readonly ScreenField[],
  second: readonly ScreenField[],
): ScreenField[] {
  const seen = new Set<string>();
  return [...first, ...second].filter((field) => {
    if (seen.has(field.name)) return false;
    seen.add(field.name);
    return true;
  });
}

function formPreset(
  data: Record<string, unknown>,
  explicit: Record<string, unknown>,
): Record<string, unknown> {
  const expectedVersion = optimisticVersion(data);
  return {
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    ...explicit,
  };
}

function actionPreset(
  event: RequestEvent,
  screen: ScreenViewModel,
  action: ScreenViewModel["actions"][number],
): Record<string, unknown> {
  const explicit = recordProperty(action, "preset");
  const operationId = actionOperationId(screen, action);
  if (operationId === "createDatasetExport")
    return {
      filters: {},
      expires_in_seconds: 86_400,
      ...explicit,
    };
  if (operationId !== "createSubscription") return explicit;
  return subscriptionPreset(explicit, event.url, event.params);
}

function actionOperationId(
  screen: ScreenViewModel,
  action: ScreenViewModel["actions"][number],
): string | undefined {
  const declared = stringProperty(action, "operation_id");
  if (declared) return declared;
  return screen.id === "PUB-020" && action.id === "download-dataset"
    ? "createDatasetExport"
    : undefined;
}

function checkAnonymousRateLimit(
  event: RequestEvent,
  operationId: string,
  payload: Record<string, unknown>,
): { status: number; message: string } | undefined {
  if (!isAnonymousSubmissionOperation(operationId)) return undefined;
  let clientAddress: string;
  try {
    clientAddress = event.getClientAddress().trim().toLowerCase();
  } catch {
    return {
      status: 503,
      message:
        "요청 출처를 확인할 수 없어 익명 제출을 안전하게 처리할 수 없습니다.",
    };
  }
  if (!clientAddress)
    return {
      status: 503,
      message:
        "요청 출처를 확인할 수 없어 익명 제출을 안전하게 처리할 수 없습니다.",
    };
  const result = anonymousSubmissionRateLimiter.consume({
    clientAddress,
    operationId,
    destination: anonymousDestination(operationId, payload, clientAddress),
    key: requiredServerValue(env, "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT"),
  });
  if (result.allowed) return undefined;
  event.setHeaders({ "retry-after": String(result.retryAfterSeconds) });
  return {
    status: 429,
    message: `요청이 너무 많습니다. ${result.retryAfterSeconds}초 후 다시 시도해 주세요.`,
  };
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
