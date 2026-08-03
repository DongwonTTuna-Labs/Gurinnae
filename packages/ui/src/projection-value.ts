import { presentEnumValue } from "./enum-presentation";
import type {
  PresentedProjectionValue,
  PresentedScalarValue,
  ProjectionPresentationOptions,
  ProjectionValue,
} from "./projection-value-types";

export type * from "./projection-value-types";

const numberFormatter = new Intl.NumberFormat("ko-KR", {
  maximumFractionDigits: 2,
});
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const isoDatePattern =
  /^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2}))?$/u;
const explicitMoneyFieldPattern =
  /(amount|cost|expense|fee|funding|krw|price|revenue|spend)/iu;
const budgetMoneyFieldPattern =
  /budget.*(amount|limit)|(amount|limit).*budget/iu;
const nonMoneyFieldPattern =
  /(count|currency|digest|rateLimit|state|status|version)|(^|[._-])id([._-]|$)|Id$/iu;
const durationFieldPattern =
  /(^|[._-])(cooldown|delay|duration|interval|latency|seconds?|timeout|ttl)([._-]|$)|(cooldown|delay|duration|interval|latency|seconds?|timeout|ttl)$/iu;
const millisecondFieldPattern = /(milliseconds?|millis|_ms|\.ms$)/iu;
const technicalIdentifierFieldPattern =
  /(digest|family|hash|href|identifier|locator|model|sha\d*|url|version)|(^|[._-])id([._-]|$)|Ids?$/iu;

export function presentProjectionValue(
  fieldName: string,
  value: ProjectionValue | null,
  options: ProjectionPresentationOptions = {},
): PresentedProjectionValue | null {
  if (value === null) return null;
  if (typeof value === "string")
    return presentString(fieldName, value, options);
  if (typeof value === "number") return presentNumber(fieldName, value);
  if (typeof value === "boolean")
    return {
      kind: "scalar",
      valueKind: "boolean",
      text: value ? "예" : "아니오",
    };
  if (value.kind === "list") {
    const items = value.items.flatMap((item) => {
      const presented = presentProjectionValue(fieldName, item, options);
      return presented ? [presented] : [];
    });
    return items.length > 0
      ? { kind: "list", items, omittedCount: value.omittedCount }
      : null;
  }
  const entries = value.entries.flatMap((entry) => {
    const presented = presentProjectionValue(entry.name, entry.value, options);
    return presented
      ? [{ name: entry.name, label: entry.label, value: presented }]
      : [];
  });
  return entries.length > 0
    ? { kind: "record", entries, omittedCount: value.omittedCount }
    : null;
}

/** Text-only projection for clipboard/plain-text surfaces; structures stay omitted. */
export function projectionScalarText(
  fieldName: string,
  value: ProjectionValue | null,
): string | null {
  const presented = presentProjectionValue(fieldName, value);
  if (presented?.kind !== "scalar") return null;
  return presented.secondary
    ? `${presented.text} · ${presented.secondary}`
    : presented.text;
}

function presentString(
  fieldName: string,
  value: string,
  options: ProjectionPresentationOptions,
): PresentedScalarValue | null {
  const normalized = value.trim();
  if (!normalized) return null;
  if (uuidPattern.test(normalized)) {
    return {
      kind: "scalar",
      valueKind: "uuid",
      text: `${normalized.slice(0, 8)}…`,
      title: normalized,
      copyText: normalized,
    };
  }
  const date = isoDate(normalized);
  if (date) return presentDate(date, options.relativeTo);
  const numeric = numericString(normalized);
  if (numeric !== null && isMoneyField(fieldName))
    return presentMoney(fieldName, numeric);
  if (numeric !== null && isDurationField(fieldName))
    return presentDuration(fieldName, numeric);
  if (technicalIdentifierFieldPattern.test(fieldName))
    return { kind: "scalar", valueKind: "text", text: normalized };
  const enumText = presentEnumValue(normalized);
  return {
    kind: "scalar",
    valueKind: enumText === normalized ? "text" : "enum",
    text: enumText,
  };
}

function presentNumber(fieldName: string, value: number): PresentedScalarValue {
  if (isMoneyField(fieldName)) return presentMoney(fieldName, value);
  if (isDurationField(fieldName)) return presentDuration(fieldName, value);
  return {
    kind: "scalar",
    valueKind: "number",
    text: Number.isFinite(value)
      ? numberFormatter.format(value)
      : String(value),
  };
}

function presentDate(
  date: Date,
  relativeTo: Date | undefined,
): PresentedScalarValue {
  const text = `${date.getUTCFullYear()}.${twoDigits(date.getUTCMonth() + 1)}.${twoDigits(date.getUTCDate())}`;
  const hasTime =
    date.getUTCHours() !== 0 ||
    date.getUTCMinutes() !== 0 ||
    date.getUTCSeconds() !== 0;
  const title = hasTime
    ? `${text} ${twoDigits(date.getUTCHours())}:${twoDigits(date.getUTCMinutes())} UTC`
    : text;
  const secondary = relativeTo ? relativeDate(date, relativeTo) : null;
  return {
    kind: "scalar",
    valueKind: "date",
    text,
    title,
    ...(secondary ? { secondary } : {}),
  };
}

function presentMoney(
  fieldName: string,
  sourceValue: number,
): PresentedScalarValue {
  const value = /micros?krw/iu.test(fieldName)
    ? sourceValue / 1_000_000
    : sourceValue;
  const secondary = compactWon(value);
  return {
    kind: "scalar",
    valueKind: "money",
    text: `₩${numberFormatter.format(value)}`,
    ...(secondary ? { secondary } : {}),
  };
}

function presentDuration(
  fieldName: string,
  sourceValue: number,
): PresentedScalarValue {
  const seconds = millisecondFieldPattern.test(fieldName)
    ? sourceValue / 1_000
    : sourceValue;
  return {
    kind: "scalar",
    valueKind: "duration",
    text: durationText(seconds),
  };
}

function isoDate(value: string): Date | null {
  if (!isoDatePattern.test(value)) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function numericString(value: string): number | null {
  if (!/^-?\d+(?:\.\d+)?$/u.test(value)) return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function isMoneyField(fieldName: string): boolean {
  return (
    (explicitMoneyFieldPattern.test(fieldName) ||
      budgetMoneyFieldPattern.test(fieldName)) &&
    !nonMoneyFieldPattern.test(fieldName)
  );
}

function isDurationField(fieldName: string): boolean {
  return durationFieldPattern.test(fieldName);
}

function compactWon(value: number): string | null {
  const absolute = Math.abs(value);
  if (absolute >= 100_000_000)
    return `약 ${numberFormatter.format(value / 100_000_000)}억 원`;
  if (absolute >= 10_000)
    return `약 ${numberFormatter.format(value / 10_000)}만 원`;
  return null;
}

function durationText(seconds: number): string {
  if (!Number.isFinite(seconds)) return String(seconds);
  const sign = seconds < 0 ? "-" : "";
  const remaining = Math.abs(seconds);
  if (remaining < 60) return `${sign}${numberFormatter.format(remaining)}초`;
  const units = [
    [86_400, "일"],
    [3_600, "시간"],
    [60, "분"],
    [1, "초"],
  ] as const;
  let rest = Math.floor(remaining);
  const parts: string[] = [];
  for (const [size, label] of units) {
    const count = Math.floor(rest / size);
    if (count > 0) parts.push(`${count}${label}`);
    rest %= size;
    if (parts.length === 2) break;
  }
  return `${sign}${parts.join(" ")}`;
}

function relativeDate(value: Date, relativeTo: Date): string {
  const differenceSeconds = Math.round(
    (value.getTime() - relativeTo.getTime()) / 1_000,
  );
  const absolute = Math.abs(differenceSeconds);
  if (absolute < 60) return differenceSeconds >= 0 ? "곧" : "방금 전";
  const [divisor, unit] =
    absolute >= 86_400
      ? ([86_400, "일"] as const)
      : absolute >= 3_600
        ? ([3_600, "시간"] as const)
        : ([60, "분"] as const);
  const amount = Math.round(absolute / divisor);
  return differenceSeconds >= 0 ? `${amount}${unit} 후` : `${amount}${unit} 전`;
}

function twoDigits(value: number): string {
  return String(value).padStart(2, "0");
}
