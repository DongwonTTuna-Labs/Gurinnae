export function subscriptionPreset(
  explicit: Readonly<Record<string, unknown>>,
  url: URL,
  params: Readonly<Record<string, string | undefined>>,
): Record<string, unknown> {
  const transported = transportedSubscriptionPreset(url);
  const preset = { ...transported, ...explicit };
  const scopeType = preset.scope_type ?? preset.scopeType;
  if (scopeType === "CASE")
    return {
      ...preset,
      scope_ref:
        preset.scope_ref ??
        preset.scopeRef ??
        requiredRouteParam(params, "caseSlug"),
    };
  if (scopeType === "AGENCY")
    return {
      ...preset,
      scope_ref:
        preset.scope_ref ??
        preset.scopeRef ??
        requiredRouteParam(params, "agencySlug"),
    };
  if (scopeType === "SUPPLIER")
    return {
      ...preset,
      scope_ref:
        preset.scope_ref ??
        preset.scopeRef ??
        requiredRouteParam(params, "supplierSlug"),
    };
  if (scopeType === "REGION") {
    const scopeRef = preset.scope_ref ?? preset.scopeRef;
    return typeof scopeRef === "string" && isSigunguCode(scopeRef)
      ? { ...preset, scope_ref: scopeRef }
      : preset;
  }
  if (scopeType === "QUERY")
    return { ...preset, query: preset.query ?? subscriptionQuery(url) };
  return preset;
}

const TRANSPORTED_SCOPES = new Set([
  "CASE",
  "AGENCY",
  "SUPPLIER",
  "REGION",
  "CORRECTIONS",
]);
const QUERY_FILTERS = new Set([
  "agencyId",
  "hasCorrection",
  "hasResponse",
  "publicationState",
  "publishedFrom",
  "publishedTo",
  "ruleId",
  "sidoCode",
  "sigunguCode",
  "supplierId",
]);

function transportedSubscriptionPreset(url: URL): Record<string, unknown> {
  const scopeType = url.searchParams.get("scope");
  if (scopeType === "QUERY") {
    const query = transportedQuery(url.searchParams.get("query"));
    return query ? { scope_type: scopeType, query } : {};
  }
  if (!scopeType || !TRANSPORTED_SCOPES.has(scopeType)) return {};
  if (["CASE", "AGENCY", "SUPPLIER", "REGION"].includes(scopeType)) {
    const scopeRef = url.searchParams.get("ref");
    const validReference =
      scopeType === "REGION"
        ? scopeRef !== null && isSigunguCode(scopeRef)
        : scopeRef !== null && isPublicRouteIdentifier(scopeRef);
    return validReference ? { scope_type: scopeType, scope_ref: scopeRef } : {};
  }
  return { scope_type: scopeType };
}

function transportedQuery(
  raw: string | null,
): Record<string, unknown> | undefined {
  if (!raw) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!isRecord(parsed) || parsed.route !== "/cases") return undefined;
  if (typeof parsed.sort !== "string" || !boundedText(parsed.sort, 128))
    return undefined;
  if (
    !Array.isArray(parsed.filters) ||
    parsed.filters.length > QUERY_FILTERS.size
  )
    return undefined;

  const seen = new Set<string>();
  const filters: Array<{ name: string; values: string[] }> = [];
  for (const filter of parsed.filters) {
    if (!isRecord(filter) || typeof filter.name !== "string") return undefined;
    if (!QUERY_FILTERS.has(filter.name) || seen.has(filter.name))
      return undefined;
    if (!Array.isArray(filter.values) || filter.values.length === 0)
      return undefined;
    const values = filter.values.filter(
      (value): value is string =>
        typeof value === "string" && boundedText(value, 512),
    );
    if (values.length !== filter.values.length) return undefined;
    if (
      (filter.name === "sidoCode" &&
        (values.length !== 1 || !values.every(isSidoCode))) ||
      (filter.name === "sigunguCode" &&
        (values.length !== 1 || !values.every(isSigunguCode)))
    )
      return undefined;
    seen.add(filter.name);
    filters.push({ name: filter.name, values: [...values].sort() });
  }
  filters.sort((left, right) => left.name.localeCompare(right.name));
  const sidoCode = filters.find(({ name }) => name === "sidoCode")?.values[0];
  const sigunguCode = filters.find(({ name }) => name === "sigunguCode")
    ?.values[0];
  if (sidoCode && sigunguCode && !sigunguCode.startsWith(sidoCode))
    return undefined;
  return { route: "/cases", filters, sort: parsed.sort };
}

function boundedText(value: string, maxLength: number): boolean {
  return (
    value.length > 0 && value.length <= maxLength && value.trim() === value
  );
}

function isPublicRouteIdentifier(value: string): boolean {
  return /^[A-Za-z0-9._~-]{1,128}$/u.test(value);
}

function isSigunguCode(value: string): boolean {
  return /^\d{5}$/u.test(value);
}

function isSidoCode(value: string): boolean {
  return /^\d{2}$/u.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function subscriptionQuery(url: URL): Record<string, unknown> {
  const ignored = new Set([
    "cursor",
    "limit",
    "notice",
    "q",
    "search",
    "sort",
    "token",
  ]);
  const names = [...new Set(url.searchParams.keys())]
    // SvelteKit named form actions encode the action as a synthetic
    // `?/action-id` query key on the POST URL. It is transport metadata,
    // never a user-selected subscription filter, so exclude it before the
    // server-bound query snapshot is persisted.
    .filter((name) => !ignored.has(name) && !name.startsWith("/"))
    .sort();
  const filters = names.map((name) => ({
    name,
    values: url.searchParams.getAll(name).sort(),
  }));
  const search = url.searchParams.get("search") ?? url.searchParams.get("q");
  return {
    route: url.pathname,
    ...(search ? { search } : {}),
    filters,
    sort: url.searchParams.get("sort") ?? "updated_desc",
  };
}

export function handle__j01__create_subscription_verification_receipt_v1(
  receipt: Readonly<Record<string, unknown>>,
): boolean {
  return receipt.verificationDispatched === true;
}

export function caseSubscriptionReturnTo(
  url: URL,
  payload: Readonly<Record<string, unknown>>,
  receipt: Readonly<Record<string, unknown>>,
): string | undefined {
  const candidate = url.searchParams.get("returnTo");
  const match = candidate
    ? /^\/cases\/([A-Za-z0-9._~-]{1,128})$/u.exec(candidate)
    : null;
  if (
    !candidate ||
    !match?.[1] ||
    !handle__j01__create_subscription_verification_receipt_v1(receipt) ||
    payload.scopeType !== "CASE" ||
    payload.scopeRef !== match[1]
  )
    return undefined;
  return candidate;
}

export const route__j01__return_after_subscription_v1 =
  caseSubscriptionReturnTo;

function requiredRouteParam(
  params: Readonly<Record<string, string | undefined>>,
  name: string,
): string {
  const value = params[name];
  if (!value) throw new Error(`구독 대상 ${name}이 없습니다.`);
  return value;
}
