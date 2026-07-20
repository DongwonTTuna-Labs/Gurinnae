import type { ScreenRuntime } from "./index";

export type SemanticRecord = {
  record: Record<string, unknown>;
};

const sensitive =
  /(authorization|cookie|credential|encrypted|password|secret|token)/i;
const displayFieldKeys = new Set([
  "title",
  "summary",
  "description",
  "status",
  "state",
  "publicState",
  "publicationState",
  "owner",
  "assignedTo",
  "dueAt",
  "expiresAt",
  "createdAt",
  "updatedAt",
  "publishedAt",
  "occurredAt",
  "reason",
  "decision",
  "receipt",
  "evidence",
  "source",
  "locator",
  "version",
  "digest",
  "count",
  "items",
  "questions",
  "answers",
  "attachments",
  "consent",
  "citations",
  "links",
  "health",
  "readiness",
  "filename",
  "mediaType",
  "sizeBytes",
  "uploadStatus",
  "scanStatus",
  "nextAction",
  "remainingAttempts",
  "requiresEmailProof",
  "statement",
  "requestedUntil",
  "remainingQuestions",
  "savedAt",
  "activatedAt",
]);

export function semanticRecords(runtime: ScreenRuntime): SemanticRecord[] {
  const output: SemanticRecord[] = [];
  for (const value of Object.values(runtime.data)) {
    if (!isRecord(value)) continue;
    const records = Array.isArray(value.items) ? value.items : [value];
    for (const record of records) {
      if (isRecord(record)) output.push({ record });
    }
  }
  return output;
}

export function visibleEntries(
  record: Record<string, unknown>,
): Array<[string, unknown]> {
  return Object.entries(record)
    .filter(([key]) => displayFieldKeys.has(key) && !sensitive.test(key))
    .map(([key, value]) => [key, redact(key, value)]);
}

export function display(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "예" : "아니오";
  if (Array.isArray(value)) {
    if (value.length === 0) return "목록 없음";
    const preview = value
      .slice(0, 4)
      .map((item) => displayStructured(item))
      .join(" · ");
    return value.length > 4 ? `${preview} · 외 ${value.length - 4}건` : preview;
  }
  if (typeof value === "object") {
    return displayStructured(value);
  }
  return String(value);
}

function displayStructured(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "예" : "아니오";
  if (typeof value === "number" || typeof value === "string")
    return String(value);
  if (Array.isArray(value)) {
    return value.slice(0, 4).map(displayStructured).join(" · ") || "목록 없음";
  }
  if (isRecord(value)) {
    const entries = Object.entries(value)
      .filter(([key]) => !sensitive.test(key))
      .slice(0, 6)
      .map(([key, item]) => `${key}: ${displayStructured(item)}`);
    return entries.join(" · ") || "세부 정보 없음";
  }
  return "확인 필요";
}

export function firstValue(
  record: Record<string, unknown>,
  candidates: readonly string[],
): string {
  for (const candidate of candidates) {
    const entry = Object.entries(record).find(
      ([key]) => key.toLowerCase() === candidate.toLowerCase(),
    );
    if (entry && entry[1] !== null && entry[1] !== undefined)
      return display(entry[1]);
  }
  return "확인 필요";
}

function redact(key: string, value: unknown): unknown {
  return sensitive.test(key) ? "보호됨" : redactObject(value);
}

function redactObject(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactObject);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [key, redact(key, item)]),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
