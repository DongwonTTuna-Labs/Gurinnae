type ReadonlyFieldDisplayInput = {
  readonly name: string;
  readonly value?: string | number | boolean;
};

const QUERY_ROUTE_LABELS: Readonly<Record<string, string>> = {
  "/cases": "공개 사례 목록",
};

const QUERY_SORT_LABELS: Readonly<Record<string, string>> = {
  updated_desc: "최근 갱신순",
  published_desc: "최근 공개순",
  title_asc: "제목순",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNamedFilter(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    value.name.length > 0 &&
    Array.isArray(value.values) &&
    value.values.every((item) => typeof item === "string")
  );
}

function subscriptionQuerySummary(value: unknown): string {
  if (typeof value !== "string") return "확인 필요";
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return "확인 필요";
  }
  if (!isRecord(parsed)) return "확인 필요";
  const routeLabel =
    typeof parsed.route === "string"
      ? QUERY_ROUTE_LABELS[parsed.route]
      : undefined;
  const sortLabel =
    typeof parsed.sort === "string"
      ? QUERY_SORT_LABELS[parsed.sort]
      : undefined;
  const search = parsed.search;
  if (
    !routeLabel ||
    !sortLabel ||
    !Array.isArray(parsed.filters) ||
    !parsed.filters.every(isNamedFilter) ||
    (search !== undefined && typeof search !== "string")
  )
    return "확인 필요";
  return [
    routeLabel,
    ...(search?.trim() ? ["검색어 포함"] : []),
    `필터 ${parsed.filters.length}개`,
    sortLabel,
  ].join(" · ");
}

export function displayReadonlyFieldValue(
  field: ReadonlyFieldDisplayInput,
): string {
  if (field.value === undefined) return "—";
  return field.name === "query"
    ? subscriptionQuerySummary(field.value)
    : String(field.value);
}
