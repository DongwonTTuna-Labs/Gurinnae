import { randomUUID } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  optimisticVersion,
  requiredServerValue,
  type SubmissionSessionKind,
  serviceAssertionFetch,
} from "@gurine/config";
import type { AttachmentRemovalItem, ScreenViewModel } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { ATTACHMENT_ACCEPT, operations } from "./screen-contract";
export function renderRoute(
  route: string,
  params: Record<string, string | undefined>,
): string {
  return route.replaceAll(
    /\{([^}]+)\}/g,
    (_, key: string) => params[key] ?? "",
  );
}
export function withoutToken(url: URL, notice?: string): string {
  const clean = new URL(url);
  clean.searchParams.delete("token");
  if (notice) clean.searchParams.set("notice", notice);
  return `${clean.pathname}${clean.search}${clean.hash}`;
}
export function definedParams(
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(params).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );
}
export function operationFormPathParams(
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
export function sameOrigin(event: RequestEvent): boolean {
  const origin = event.request.headers.get("origin");
  const fetchSite = event.request.headers.get("sec-fetch-site");
  return (
    origin === event.url.origin && (!fetchSite || fetchSite === "same-origin")
  );
}
export function normalize(
  value: Record<string, unknown>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key.replaceAll(/_([a-z])/g, (_, letter: string) => letter.toUpperCase()),
      item,
    ]),
  );
}
export function bindRouteValues(
  value: Record<string, unknown>,
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  const output = { ...value };
  for (const [name, item] of Object.entries(params)) {
    if (item !== undefined && name in output) output[name] = item;
  }
  return output;
}
export function actionIdempotencyKeys(
  screen: ScreenViewModel,
): Readonly<Record<string, string>> {
  return Object.fromEntries(
    screen.actions
      .filter((action) => stringProperty(action, "operation_id"))
      .map((action) => [action.id, randomUUID()]),
  );
}
export function formIdempotencyKey(form: FormData): string {
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
export function sessionKindsForOperation(
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
export function formPreset(
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
export async function loadResponseDraft(
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
export function problemTitle(value: unknown, status: number): string {
  return isRecord(value) && typeof value.title === "string"
    ? value.title
    : `요청 실패 (${status})`;
}
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function stringProperty(
  value: Record<string, unknown>,
  key: string,
): string | undefined {
  const item = value[key];
  return typeof item === "string" ? item : undefined;
}
export function recordProperty(
  value: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const item = value[key];
  return isRecord(item) ? item : {};
}
export function uuidProperty(
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
export function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}
export function attachmentItems(
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
export function hasOperation(
  screen: ScreenViewModel,
  operationId: string,
): boolean {
  return screen.dataOperations.some(
    (operation) => operation.operation_id === operationId,
  );
}
export function safeFilename(value: string): string {
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
export function attachmentMediaType(file: File): string | undefined {
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
export function isRedirect(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.status === "number" &&
    value.status >= 300 &&
    value.status < 400
  );
}
