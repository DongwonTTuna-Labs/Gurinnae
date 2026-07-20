import { humanFieldLabel } from "./screen-contract";
import type { SafeProjectionValue } from "./screen-projection";

/** Field names that must never be rendered into browser-facing text. */
export const sensitiveName =
  /(token|secret|cookie|credential|authorization|password|assertion)/i;

export function labelFor(name: string): string {
  const labels: Record<string, string> = {
    id: "식별자",
    status: "현재 상태",
    state: "진행 상태",
    summary: "요약",
    description: "설명",
    owner: "담당자",
    due_at: "기한",
    updated_at: "마지막 변경",
    created_at: "생성 시각",
    source: "출처",
    evidence: "근거",
    digest: "무결성 지문",
    count: "건수",
    next_action: "다음 행동",
  };
  if (labels[name]) return labels[name];
  const normalized = humanFieldLabel(name);
  return normalized === name ? "확인 항목" : normalized;
}

/** Reduce arbitrary operation values to bounded, browser-safe text. */
export function safeProjectionValue(
  value: unknown,
): SafeProjectionValue | null {
  if (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  )
    return value;
  if (Array.isArray(value)) {
    const parts = value
      .slice(0, 4)
      .map((item) => safeStructuredText(item))
      .filter(Boolean);
    return parts.length > 0
      ? `${parts.join(" · ")}${value.length > 4 ? ` · 외 ${value.length - 4}건` : ""}`
      : null;
  }
  if (value && typeof value === "object") {
    const parts = Object.entries(value as Record<string, unknown>)
      .filter(([key]) => !sensitiveName.test(key))
      .slice(0, 6)
      .map(([key, item]) => `${labelFor(key)}: ${safeStructuredText(item)}`);
    return parts.length > 0 ? parts.join(" · ") : null;
  }
  return null;
}

function safeStructuredText(value: unknown): string {
  if (value === null || value === undefined || value === "") return "확인 필요";
  if (typeof value === "string" || typeof value === "number")
    return String(value);
  if (typeof value === "boolean") return value ? "예" : "아니오";
  if (Array.isArray(value))
    return value.slice(0, 3).map(safeStructuredText).join(", ") || "목록 없음";
  if (typeof value === "object") {
    return (
      Object.entries(value as Record<string, unknown>)
        .filter(([key]) => !sensitiveName.test(key))
        .slice(0, 3)
        .map(([key, item]) => `${labelFor(key)} ${safeStructuredText(item)}`)
        .join(", ") || "세부 정보 없음"
    );
  }
  return "확인 필요";
}
