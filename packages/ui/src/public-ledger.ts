import {
  type ProjectionPrimitive,
  presentProjectionValue,
} from "./projection-value";
import type { PublicStatusNotice } from "./public-status-notice";

export const PUBLIC_LEDGER_CONTRACTS = {
  "PUB-001": {
    sectionId: "recent",
    actionId: "open-case",
    ownsAction: false,
  },
  "PUB-002": {
    sectionId: "results",
    actionId: "open-result",
    ownsAction: true,
  },
  "PUB-003": {
    sectionId: "results",
    actionId: "open-case",
    ownsAction: true,
  },
  "PUB-007": {
    sectionId: "results",
    actionId: "open-agency",
    ownsAction: true,
  },
  "PUB-009": {
    sectionId: "results",
    actionId: "open-supplier",
    ownsAction: true,
  },
  "PUB-011": {
    sectionId: "results",
    actionId: "open-contract",
    ownsAction: true,
  },
  "PUB-015": {
    sectionId: "sources",
    actionId: "open-source",
    ownsAction: false,
  },
  "PUB-016": {
    sectionId: "list",
    actionId: "open-source",
    ownsAction: false,
  },
  "PUB-018": {
    sectionId: "records",
    actionId: "open-correction",
    ownsAction: true,
  },
  "PUB-034": {
    sectionId: "impact",
    actionId: "open-source",
    ownsAction: false,
  },
} as const;

export const PUBLIC_LEDGER_SCREEN_IDS = Object.keys(
  PUBLIC_LEDGER_CONTRACTS,
) as readonly PublicLedgerScreenId[];

export type PublicLedgerScreenId = keyof typeof PUBLIC_LEDGER_CONTRACTS;
export type PublicLedgerActionId =
  (typeof PUBLIC_LEDGER_CONTRACTS)[PublicLedgerScreenId]["actionId"];
export type PublicLedgerStatusTone =
  | "critical"
  | "neutral"
  | "positive"
  | "warning";

/** Browser-safe scalar prepared at the server boundary. */
export type PublicLedgerCell = Readonly<{
  label: string;
  text: string;
  secondary?: string;
  title?: string;
  copyText?: string;
}>;

export type PublicLedgerRow = Readonly<{
  key: string;
  identifier: PublicLedgerCell;
  title: PublicLedgerCell;
  summary?: PublicLedgerCell;
  kind: PublicLedgerCell;
  /** Explicit on every row; null is allowed only for kinds without a public status. */
  notice: PublicStatusNotice | null;
  status?: Readonly<{
    label: string;
    text: string;
    tone: PublicLedgerStatusTone;
  }>;
  metric?: PublicLedgerCell;
  href?: string;
}>;

export type PublicLedgerViewModel = Readonly<{
  screenId: PublicLedgerScreenId;
  sectionId: string;
  actionId: PublicLedgerActionId;
  collectionNotices: readonly PublicStatusNotice[];
  rows: readonly PublicLedgerRow[];
}>;

export type PublicLedgerRenderState = Readonly<{
  projectionState:
    | "BLOCKED"
    | "EMPTY"
    | "ERROR"
    | "LOADING"
    | "PARTIAL"
    | "READY"
    | "STALE"
    | "UNKNOWN";
  message?: string;
  showRows: boolean;
  alert: boolean;
}>;

const detailPaths: Readonly<Record<PublicLedgerActionId, readonly RegExp[]>> = {
  "open-result": [
    /^\/agencies\/[A-Za-z0-9._~-]+\/?$/,
    /^\/cases\/[A-Za-z0-9._~-]+\/?$/,
    /^\/contracts\/[A-Za-z0-9._~-]+\/?$/,
    /^\/corrections\/[A-Za-z0-9._~-]+\/?$/,
    /^\/data\/?$/,
    /^\/methodology\/rules\/[A-Za-z0-9._~-]+\/?$/,
    /^\/sources\/[A-Za-z0-9._~-]+\/?$/,
    /^\/suppliers\/[A-Za-z0-9._~-]+\/?$/,
  ],
  "open-case": [/^\/cases\/[A-Za-z0-9._~-]+\/?$/],
  "open-agency": [/^\/agencies\/[A-Za-z0-9._~-]+\/?$/],
  "open-supplier": [/^\/suppliers\/[A-Za-z0-9._~-]+\/?$/],
  "open-contract": [/^\/contracts\/[A-Za-z0-9._~-]+\/?$/],
  "open-source": [/^\/sources\/[A-Za-z0-9._~-]+\/?$/],
  "open-correction": [/^\/corrections\/[A-Za-z0-9._~-]+\/?$/],
};

/**
 * Converts one explicitly selected scalar into a browser-safe cell. Raw DTO
 * traversal belongs to the server mapper; this helper only handles display.
 */
export function publicLedgerCell(
  fieldName: string,
  label: string,
  value: ProjectionPrimitive,
): PublicLedgerCell {
  const presented = presentProjectionValue(fieldName, value);
  if (presented?.kind !== "scalar")
    throw new Error(`공개 대장 표시 계약 불일치: ${fieldName}`);
  return {
    label,
    text: presented.text,
    ...(presented.secondary ? { secondary: presented.secondary } : {}),
    ...(presented.title ? { title: presented.title } : {}),
    ...(presented.copyText ? { copyText: presented.copyText } : {}),
  };
}

export function publicLedgerOwnsAction(
  screenId: string,
  actionId: string,
): boolean {
  const contract = publicLedgerContract(screenId);
  return contract?.ownsAction === true && contract.actionId === actionId;
}

/** Fail closed when a server mapper wires a ledger to the wrong screen/section. */
export function publicLedgerForSection(
  viewModel: PublicLedgerViewModel | undefined,
  screenId: string,
  sectionId: string,
): PublicLedgerViewModel | undefined {
  const contract = publicLedgerContract(screenId);
  if (!contract || contract.sectionId !== sectionId) {
    if (viewModel)
      throw new Error(`공개 대장 화면 계약 불일치: ${screenId}.${sectionId}`);
    return undefined;
  }
  if (!viewModel) return undefined;
  if (
    viewModel.screenId !== screenId ||
    viewModel.sectionId !== sectionId ||
    viewModel.actionId !== contract.actionId
  )
    throw new Error(`공개 대장 런타임 계약 불일치: ${screenId}.${sectionId}`);

  if (
    !Object.hasOwn(viewModel, "collectionNotices") ||
    !Array.isArray(viewModel.collectionNotices) ||
    viewModel.collectionNotices.length === 0
  )
    throw new Error(`공개 대장 전체 상태 고지 계약 누락: ${screenId}`);
  if (viewModel.collectionNotices.length > 1)
    throw new Error(`공개 대장 전체 상태 고지 중복: ${screenId}`);
  const collectionNoticeKeys = new Set<string>();
  for (const [index, notice] of viewModel.collectionNotices.entries()) {
    const key = collectionNoticeKey(notice, screenId, index);
    if (collectionNoticeKeys.has(key))
      throw new Error(
        `공개 대장 전체 상태 고지 중복: ${screenId} ${index + 1}번째`,
      );
    collectionNoticeKeys.add(key);
  }

  const keys = new Set<string>();
  for (const [index, row] of viewModel.rows.entries()) {
    if (!Object.hasOwn(row, "notice"))
      throw new Error(
        `공개 대장 상태 고지 계약 누락: ${screenId} ${index + 1}행`,
      );
    if (!row.key.trim() || keys.has(row.key))
      throw new Error(`공개 대장 행 식별자 불일치: ${screenId} ${index + 1}행`);
    keys.add(row.key);
    for (const cell of [row.identifier, row.title, row.kind])
      assertCell(cell, screenId, index);
    if (row.summary) assertCell(row.summary, screenId, index);
    if (row.metric) assertCell(row.metric, screenId, index);
    if (row.status && (!row.status.label.trim() || !row.status.text.trim()))
      throw new Error(`공개 대장 상태 값 누락: ${screenId} ${index + 1}행`);
    if (row.href && !isAllowlistedHref(row.href, viewModel.actionId))
      throw new Error(`공개 대장 이동 경로 불일치: ${screenId} ${index + 1}행`);
  }
  return viewModel;
}

/** Exactly one verified row owns the action hook; all rows remain links. */
export function publicLedgerActionRowIndex(
  viewModel: PublicLedgerViewModel | undefined,
): number {
  if (!viewModel || !publicLedgerContract(viewModel.screenId)?.ownsAction)
    return -1;
  return viewModel.rows.findIndex((row) => row.href !== undefined);
}

export function publicLedgerRenderState(
  runtimeState: string,
  viewModel: PublicLedgerViewModel | undefined,
): PublicLedgerRenderState {
  if (["loading", "initial-loading", "refreshing"].includes(runtimeState))
    return state("LOADING", "공개 기록을 불러오는 중입니다.");
  if (
    ["blocked", "conflict", "forbidden", "unauthorized"].includes(runtimeState)
  )
    return state(
      "BLOCKED",
      "필수 확인이 끝나지 않아 목록을 표시하지 않습니다.",
      true,
    );
  if (["error", "server-error", "offline"].includes(runtimeState))
    return state(
      "ERROR",
      "목록을 불러오지 못했습니다. 잠시 후 다시 시도하세요.",
      true,
    );
  if (runtimeState === "stale")
    return state("STALE", "목록이 오래되었습니다. 최신 상태를 확인하세요.");
  if (!viewModel) {
    if (runtimeState === "awaiting-query")
      return state("EMPTY", "검색어 입력 대기");
    return state("UNKNOWN", "현재 범위의 목록을 확인할 수 없습니다.");
  }
  if (viewModel.rows.length === 0)
    return state("EMPTY", "현재 조건에 맞는 공개 기록이 없습니다.");
  if (["partial", "degraded"].includes(runtimeState))
    return { projectionState: "PARTIAL", showRows: true, alert: false };
  return { projectionState: "READY", showRows: true, alert: false };
}

export function publicLedgerStatusTone(
  value: ProjectionPrimitive,
): PublicLedgerStatusTone {
  const normalized = String(value).trim().toUpperCase();
  if (
    [
      "ACTIVE",
      "AWARDED",
      "COMPLETED",
      "CORRECTED",
      "CURRENT",
      "OFFICIALLY_CONFIRMED",
      "PUBLISHED_EXPLAINED",
      "영업 중",
    ].includes(normalized)
  )
    return "positive";
  if (
    ["AWAITING_RESPONSE", "PUBLISHED_ANOMALY", "PARTIAL"].includes(normalized)
  )
    return "warning";
  if (["CANCELLED", "RETRACTED", "TEMPORARILY_RESTRICTED"].includes(normalized))
    return "critical";
  return "neutral";
}

function publicLedgerContract(screenId: string) {
  return isPublicLedgerScreenId(screenId)
    ? PUBLIC_LEDGER_CONTRACTS[screenId]
    : undefined;
}

function isPublicLedgerScreenId(value: string): value is PublicLedgerScreenId {
  return Object.hasOwn(PUBLIC_LEDGER_CONTRACTS, value);
}

function assertCell(
  cell: PublicLedgerCell,
  screenId: string,
  index: number,
): void {
  if (!cell.label.trim() || !cell.text.trim())
    throw new Error(`공개 대장 표시 값 누락: ${screenId} ${index + 1}행`);
}

function collectionNoticeKey(
  notice: unknown,
  screenId: string,
  index: number,
): string {
  if (!isRecord(notice))
    throw new Error(
      `공개 대장 전체 상태 고지 불일치: ${screenId} ${index + 1}번째`,
    );
  const { kind, label, text } = notice;
  const expectedLabel =
    kind === "NON_CONCLUSION"
      ? "비확정 고지"
      : kind === "INTERPRETATION"
        ? "상태 해석"
        : undefined;
  if (
    expectedLabel === undefined ||
    label !== expectedLabel ||
    typeof text !== "string" ||
    !text.trim()
  )
    throw new Error(
      `공개 대장 전체 상태 고지 불일치: ${screenId} ${index + 1}번째`,
    );
  return JSON.stringify([kind, text.trim()]);
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAllowlistedHref(
  href: string,
  actionId: PublicLedgerActionId,
): boolean {
  if (!href.startsWith("/") || href.startsWith("//")) return false;
  try {
    const parsed = new URL(href, "https://gurine.invalid");
    return (
      parsed.origin === "https://gurine.invalid" &&
      href === parsed.pathname &&
      detailPaths[actionId].some((pattern) => pattern.test(parsed.pathname))
    );
  } catch {
    return false;
  }
}

function state(
  projectionState: PublicLedgerRenderState["projectionState"],
  message: string,
  alert = false,
): PublicLedgerRenderState {
  return { projectionState, message, showRows: false, alert };
}
