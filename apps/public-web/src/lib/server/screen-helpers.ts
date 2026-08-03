import { createHash, randomUUID } from "node:crypto";
import {
  operationFields,
  optimisticVersion,
  requiredServerValue,
  type SubmissionSessionKind,
} from "@gurine/config";
import type {
  AttachmentRemovalItem,
  PublicLedgerActionId,
  PublicLedgerCell,
  PublicLedgerRow,
  PublicLedgerScreenId,
  RowSelectionNavigationOptions,
  ScreenField,
  ScreenViewModel,
} from "@gurine/ui";
import { publicLedgerCell, publicLedgerStatusTone } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import {
  anonymousDestination,
  anonymousSubmissionRateLimiter,
  isAnonymousSubmissionOperation,
} from "./anonymous-rate-limit";
import { ATTACHMENT_ACCEPT, operations } from "./screen-contract";
import type { readSubmissionSession } from "./submission-cookie";
import { subscriptionPreset } from "./subscription-preset";
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
export function tokenBody(
  operationId: string,
  token: string,
): Record<string, unknown> {
  return operationId === "verifySubscription"
    ? { verificationToken: token }
    : { oneTimeToken: token };
}
export function tokenDestination(url: URL, operationId: string): string {
  if (operationId !== "verifySubscription") return withoutToken(url);
  const destination = new URL("/subscription/manage", url);
  return withoutToken(destination, "구독 이메일 검증을 완료했습니다.");
}
export function sessionKindsForOperation(
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
      .filter((action) => actionOperationId(screen, action))
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

export function stableIdempotencyKey(
  operationId: string,
  body: Record<string, unknown>,
): string {
  return createHash("sha256")
    .update(JSON.stringify([operationId, body]))
    .digest("hex");
}

export function correctionBootstrapRequired(
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

export function correctionBootstrapFields(event: RequestEvent): ScreenField[] {
  const indexed = operations.get("createCorrectionRequestDraft");
  if (!indexed)
    throw new Error("createCorrectionRequestDraft contract missing");
  const locale = requestLocale(event.request);
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

export function mergeFields(
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

export function publicLedgerRow(
  screenId: PublicLedgerScreenId,
  index: number,
  cells: Pick<PublicLedgerRow, "identifier" | "kind" | "title"> & {
    summary?: PublicLedgerCell | undefined;
    status?: PublicLedgerRow["status"] | undefined;
    metric?: PublicLedgerCell | undefined;
    href?: string | undefined;
  },
): PublicLedgerRow {
  return {
    key: `${screenId}:${index}:${cells.identifier.text}`,
    identifier: cells.identifier,
    title: cells.title,
    kind: cells.kind,
    ...(cells.summary ? { summary: cells.summary } : {}),
    ...(cells.status ? { status: cells.status } : {}),
    ...(cells.metric ? { metric: cells.metric } : {}),
    ...(cells.href ? { href: cells.href } : {}),
  };
}

export function optionalLedgerCell(
  fieldName: string,
  label: string,
  value: string | number | null | undefined,
): PublicLedgerCell | undefined {
  return value === null || value === undefined
    ? undefined
    : publicLedgerCell(fieldName, label, value);
}

export function ledgerStatus(fieldName: string, label: string, value: string) {
  return {
    label,
    text: publicLedgerCell(fieldName, label, value).text,
    tone: publicLedgerStatusTone(value),
  } as const;
}

export function optionalLedgerStatus(
  fieldName: string,
  label: string,
  value: string | null | undefined,
) {
  return value === null || value === undefined
    ? undefined
    : ledgerStatus(fieldName, label, value);
}

export function verifiedLedgerHref(
  actionId: PublicLedgerActionId,
  options: RowSelectionNavigationOptions,
  labels: readonly (string | undefined)[],
): string | undefined {
  const expected = new Set(
    labels.filter((label): label is string => Boolean(label)),
  );
  const hrefs = [
    ...new Set(
      (options[actionId] ?? [])
        .filter((option) => expected.has(option.label))
        .map((option) => option.href),
    ),
  ];
  return hrefs.length === 1 ? hrefs[0] : undefined;
}

export function compactLedgerLabel(
  values: readonly (string | null | undefined)[],
) {
  const parts = values.flatMap((value) => {
    const normalized = value?.replaceAll(/\s+/gu, " ").trim();
    return normalized ? [normalized] : [];
  });
  return parts.length > 0 ? parts.join(" · ").slice(0, 120) : undefined;
}

export function formPreset(
  data: Record<string, unknown>,
  explicit: Record<string, unknown>,
): Record<string, unknown> {
  const expectedVersion = optimisticVersion(data);
  return {
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    ...explicit,
  };
}

export function actionPreset(
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
  return {
    ...subscriptionPreset(explicit, event.url, event.params),
    locale: requestLocale(event.request),
  };
}

export function requestLocale(request: Request): string {
  const ranges = request.headers.get("accept-language")?.split(",") ?? [];
  for (const range of ranges) {
    const candidate = range.split(";", 1)[0]?.trim();
    if (!candidate || candidate === "*") continue;
    try {
      const [locale] = Intl.getCanonicalLocales(candidate);
      if (locale) return locale;
    } catch {
      // Ignore invalid language ranges and continue to the next preference.
    }
  }
  return "ko-KR";
}

export function actionOperationId(
  screen: ScreenViewModel,
  action: ScreenViewModel["actions"][number],
): string | undefined {
  const declared = stringProperty(action, "operation_id");
  if (declared) return declared;
  return screen.id === "PUB-020" && action.id === "download-dataset"
    ? "createDatasetExport"
    : undefined;
}

export function checkAnonymousRateLimit(
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

export function problemTitle(value: unknown, status: number): string {
  return isRecord(value) && typeof value.title === "string"
    ? value.title
    : `요청 실패 (${status})`;
}
export function hasRecords(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return !Array.isArray(value.items) || value.items.length > 0;
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
