import type { ProjectionField, SafeProjectionValue } from "./screen-projection";

export function summarize(value: unknown): SafeProjectionValue | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const item = value as {
    status?: unknown;
    state?: unknown;
    reason?: unknown;
    count?: unknown;
    total?: unknown;
  };
  const parts: string[] = [];
  for (const [label, candidate] of [
    ["상태", item.status],
    ["상태", item.state],
    ["사유", item.reason],
    ["건수", item.count],
    ["전체", item.total],
  ] as const) {
    const safe = scalar(candidate);
    if (safe !== null) parts.push(`${label}: ${safe}`);
  }
  return parts.join(" · ") || "확인됨";
}

export function scalar(value: unknown): SafeProjectionValue | null {
  return typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
    ? value
    : null;
}

export function rowFields(
  prefix: string,
  rows: readonly Record<string, unknown>[],
  labels: readonly [string, string][],
  source: string,
): ProjectionField[] {
  return rows.flatMap((row, index) =>
    labels.flatMap(([key, label]) => {
      const value = scalar(row[key]);
      return value === null
        ? []
        : [
            {
              name: `${prefix}_${index}_${key}`,
              label: `${index + 1} · ${label}`,
              value,
              known: true,
              source: `${source}[${index}].${key}`,
            },
          ];
    }),
  );
}

export function nestedRows(
  prefix: string,
  parent: Record<string, unknown> | null,
  key: string,
  label: string,
  source: string,
): ProjectionField[] {
  const values = Array.isArray(parent?.[key]) ? (parent[key] as unknown[]) : [];
  return values.flatMap((value, index) => {
    const row =
      typeof value === "object" && value !== null && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : null;
    const displayValue = scalar(
      row?.statement ?? row?.text ?? row?.summary ?? row?.reason ?? value,
    );
    return displayValue === null
      ? []
      : [
          {
            name: `${prefix}_${key}_${index}`,
            label: `${label} ${index + 1}`,
            value: displayValue,
            known: true,
            source: `${source}.${key}[${index}]`,
          },
        ];
  });
}
