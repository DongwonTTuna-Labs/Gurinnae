import type { ScreenRuntime } from "./index";

export type OperationRecord = {
  operationId: string;
  record: Record<string, unknown>;
};

const sensitive =
  /(authorization|cookie|credential|encrypted|password|secret|token)/i;

export function operationRecords(runtime: ScreenRuntime): OperationRecord[] {
  const output: OperationRecord[] = [];
  for (const [operationId, value] of Object.entries(runtime.data)) {
    if (!isRecord(value)) continue;
    const records = Array.isArray(value.items) ? value.items : [value];
    for (const record of records) {
      if (isRecord(record)) output.push({ operationId, record });
    }
  }
  return output;
}

export function visibleEntries(
  record: Record<string, unknown>,
): Array<[string, unknown]> {
  return Object.entries(record).map(([key, value]) => [
    key,
    redact(key, value),
  ]);
}

export function display(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "예" : "아니오";
  if (typeof value === "object")
    return JSON.stringify(redactObject(value), null, 2);
  return String(value);
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
