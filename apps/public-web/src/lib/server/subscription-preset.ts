export function subscriptionPreset(
  explicit: Readonly<Record<string, unknown>>,
  url: URL,
  params: Readonly<Record<string, string | undefined>>,
): Record<string, unknown> {
  const scopeType = explicit.scope_type ?? explicit.scopeType;
  if (scopeType === "CASE")
    return {
      ...explicit,
      scope_ref: requiredRouteParam(params, "caseSlug"),
    };
  if (scopeType === "AGENCY")
    return {
      ...explicit,
      scope_ref: requiredRouteParam(params, "agencySlug"),
    };
  if (scopeType === "SUPPLIER")
    return {
      ...explicit,
      scope_ref: requiredRouteParam(params, "supplierSlug"),
    };
  if (scopeType === "QUERY")
    return { ...explicit, query: subscriptionQuery(url) };
  return { ...explicit };
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

function requiredRouteParam(
  params: Readonly<Record<string, string | undefined>>,
  name: string,
): string {
  const value = params[name];
  if (!value) throw new Error(`구독 대상 ${name}이 없습니다.`);
  return value;
}
