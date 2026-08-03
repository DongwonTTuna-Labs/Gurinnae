import { fieldLabel } from "./field-labels";
import type { SafeProjectionValue } from "./screen-projection";

/** Field names that must never be rendered into browser-facing text. */
export const sensitiveName =
  /(token|secret|cookie|credential|authorization|password|assertion)/i;

export function labelFor(name: string): string {
  return fieldLabel(name);
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
