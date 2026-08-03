import { ENUM_PRESENTATION_LABELS } from "./enum-presentation-labels";

const retainedTechnicalValues = [
  "CSV",
  "DELETE",
  "GET",
  "JSON",
  "JSONL",
  "KR",
  "KRW",
  "PARQUET",
  "POST",
  "PUT",
  "SEV0",
] as const;

/** Wire values whose standard technical spelling is intentionally visible. */
export const retainedTechnicalEnumValues: ReadonlySet<string> = new Set(
  retainedTechnicalValues,
);

/**
 * Raw values that must never appear in rendered text.
 *
 * Runtime UI smell checks consume this set directly. Explicitly retained
 * protocol abbreviations are deliberately absent.
 */
export const forbiddenRawEnumValues: ReadonlySet<string> = new Set(
  Object.keys(ENUM_PRESENTATION_LABELS),
);

export function isEnumCandidate(value: string): boolean {
  return /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$/u.test(value);
}

export function hasEnumPresentation(value: string): boolean {
  return (
    retainedTechnicalEnumValues.has(value) ||
    Object.hasOwn(ENUM_PRESENTATION_LABELS, value)
  );
}

/** Resolve an enum for browser text without changing its form/wire value. */
export function presentEnumValue(value: string): string {
  if (!isEnumCandidate(value)) return value;
  if (retainedTechnicalEnumValues.has(value)) return value;
  const label: string | undefined =
    ENUM_PRESENTATION_LABELS[value as keyof typeof ENUM_PRESENTATION_LABELS];
  if (!label) throw new Error(`한국어 enum 표현 계약 누락: ${value}`);
  return label;
}

export { ENUM_PRESENTATION_LABELS };
