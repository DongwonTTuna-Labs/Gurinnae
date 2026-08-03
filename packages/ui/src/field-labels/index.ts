import { FIELD_LABELS_A_C } from "./a-c";
import { FIELD_LABELS_D_G } from "./d-g";
import { FIELD_LABELS_H_L } from "./h-l";
import { FIELD_LABELS_M_R } from "./m-r";
import { FIELD_LABELS_S_T } from "./s-t";
import { FIELD_LABELS_U_Z } from "./u-z";

export const FIELD_LABEL_GROUPS = Object.freeze([
  FIELD_LABELS_A_C,
  FIELD_LABELS_D_G,
  FIELD_LABELS_H_L,
  FIELD_LABELS_M_R,
  FIELD_LABELS_S_T,
  FIELD_LABELS_U_Z,
]);

export const FIELD_LABELS: Readonly<Record<string, string>> = Object.freeze({
  ...FIELD_LABELS_A_C,
  ...FIELD_LABELS_D_G,
  ...FIELD_LABELS_H_L,
  ...FIELD_LABELS_M_R,
  ...FIELD_LABELS_S_T,
  ...FIELD_LABELS_U_Z,
});

export function hasFieldLabel(name: string): boolean {
  return Object.hasOwn(FIELD_LABELS, name);
}

/**
 * Resolve a browser-facing field label from the closed Korean registry.
 * Unknown names are contract drift: exposing the raw token would leak an
 * English implementation key into the product surface.
 */
export function fieldLabel(name: string): string {
  const label = FIELD_LABELS[name];
  if (!label) throw new Error(`한국어 필드 라벨 계약 누락: ${name}`);
  return label;
}

/**
 * Validate contextual copy authored by a closed specialized projection.
 * This path is deliberately distinct from field-name resolution: API-backed
 * headings and question text are content, never a fallback for an unknown key.
 */
export function explicitKoreanContextLabel(label: string): string {
  const normalized = label.trim();
  if (!normalized || !/[가-힣]/u.test(normalized))
    throw new Error(`한국어 문맥 라벨 계약 위반: ${label}`);
  return normalized;
}
