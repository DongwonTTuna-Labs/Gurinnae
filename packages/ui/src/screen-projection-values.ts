import { fieldLabel } from "./field-labels";
import type { ProjectionValue } from "./projection-value";

/** Field names that must never be rendered into browser-facing text. */
export const sensitiveName =
  /(assertion|authorization|cookie|credential|encrypted|password|secret|token)/i;

const MAX_LIST_ITEMS = 4;
const MAX_RECORD_ENTRIES = 6;

export function labelFor(name: string): string {
  return fieldLabel(name);
}

/** Reduce arbitrary operation values to a bounded, browser-safe value tree. */
export function safeProjectionValue(
  value: unknown,
  fieldName = "value",
): ProjectionValue | null {
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "string") return value.trim() ? value : null;
  if (Array.isArray(value)) {
    const items = value.slice(0, MAX_LIST_ITEMS).flatMap((item) => {
      const safe = safeProjectionValue(item, fieldName);
      return safe === null ? [] : [safe];
    });
    return items.length > 0
      ? {
          kind: "list",
          items,
          omittedCount: Math.max(0, value.length - MAX_LIST_ITEMS),
        }
      : null;
  }
  if (value && typeof value === "object") {
    const candidates = Object.entries(value as Record<string, unknown>).filter(
      ([key]) => !sensitiveName.test(key),
    );
    const prioritized = prioritizePublicStatusNotice(candidates);
    const entries = prioritized
      .slice(0, MAX_RECORD_ENTRIES)
      .flatMap(([name, item]) => {
        const safe = safeProjectionValue(item, name);
        return safe === null
          ? []
          : [{ name, label: labelFor(name), value: safe }];
      });
    return entries.length > 0
      ? {
          kind: "record",
          entries,
          omittedCount: Math.max(0, prioritized.length - MAX_RECORD_ENTRIES),
        }
      : null;
  }
  return null;
}

/** Keep a legal notice beside its status before the bounded record projection truncates. */
function prioritizePublicStatusNotice(
  entries: readonly [string, unknown][],
): readonly [string, unknown][] {
  const hasNotice = entries.some(
    ([name]) => name === "nonConclusion" || name === "interpretationNotice",
  );
  if (!hasNotice) return entries;
  const byName = new Map(entries);
  const correctionPriority =
    byName.has("sourceRevision") &&
    byName.has("reason") &&
    byName.has("publishedAt")
      ? [
          "publicState",
          "nonConclusion",
          "summary",
          "reason",
          "id",
          "publishedAt",
        ]
      : null;
  const priority = correctionPriority ?? [
    "publicState",
    "businessStatus",
    "status",
    "nonConclusion",
    "interpretationNotice",
    // Dedicated public row renderers need these values in the same bounded
    // record as the status and legal notice. Revisions and other metadata may
    // be omitted; the subject and explanatory text may not.
    "summary",
    "reason",
    "id",
    "slug",
    "title",
    "href",
  ];
  return [
    ...priority.flatMap((name) =>
      byName.has(name)
        ? ([[name, byName.get(name)]] as [string, unknown][])
        : [],
    ),
    ...entries.filter(([name]) => !priority.includes(name)),
  ];
}

export type AuthoritySectionStatus = {
  message: string;
  tone: "conflict" | "neutral" | "stale";
  suppressValues: boolean;
};

export function authoritySectionStatus(input: {
  projectionPresent: boolean;
  projectionState?: string;
  runtimeState: string;
  errorMessage?: string | null;
  declaredFieldCount: number;
  knownFieldCount: number;
}): AuthoritySectionStatus | null {
  if (!input.projectionPresent)
    return sectionStatus(
      "이 영역을 표시할 수 없습니다. 잠시 후 다시 시도하세요.",
      "conflict",
    );
  if (
    input.projectionState === "LOADING" ||
    input.runtimeState === "loading" ||
    input.runtimeState === "initial-loading"
  )
    return sectionStatus("확인된 내용을 불러오는 중입니다.", "neutral");
  if (input.projectionState === "BLOCKED")
    return sectionStatus(
      input.errorMessage ?? "필수 확인이 끝나지 않아 표시를 보류했습니다.",
      "conflict",
    );
  if (input.projectionState === "UNKNOWN")
    return sectionStatus(
      input.errorMessage ??
        "현재 범위의 데이터를 확인할 수 없습니다. 근거와 기준 시각을 확인하세요.",
      "stale",
    );
  if (input.projectionState === "ERROR")
    return sectionStatus(
      input.errorMessage ??
        "자료를 불러오지 못했습니다. 잠시 후 다시 시도하세요.",
      "conflict",
    );
  if (input.runtimeState === "error" || input.runtimeState === "server-error")
    return sectionStatus(
      "이 영역을 확인하지 못했습니다. 잠시 후 다시 시도하세요.",
      "conflict",
    );
  if (
    input.runtimeState === "forbidden" ||
    input.runtimeState === "unauthorized"
  )
    return sectionStatus(
      "현재 권한으로는 이 영역을 열 수 없습니다.",
      "conflict",
    );
  if (input.projectionState === "STALE")
    return sectionStatus(
      "자료가 오래되어 최신 상태를 확인해야 합니다.",
      "stale",
    );
  if (
    input.projectionState === "EMPTY" ||
    input.runtimeState === "empty" ||
    input.runtimeState === "filtered-empty" ||
    input.declaredFieldCount === 0 ||
    input.knownFieldCount === 0
  )
    return sectionStatus("이 범위에 확인 가능한 기록이 없습니다.", "neutral");
  if (
    input.projectionState === "PARTIAL" ||
    input.runtimeState === "stale" ||
    input.runtimeState === "partial"
  )
    return sectionStatus(
      "일부 정보가 오래되었거나 누락되었습니다. 최신 상태를 확인하세요.",
      "stale",
      false,
    );
  return null;
}

function sectionStatus(
  message: string,
  tone: AuthoritySectionStatus["tone"],
  suppressValues = true,
): AuthoritySectionStatus {
  return { message, tone, suppressValues };
}
