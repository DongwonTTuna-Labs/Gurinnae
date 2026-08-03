import {
  type ScreenViewModel,
  serverActionDestinations,
  urlFilterContractFor,
} from "@gurine/ui";
import * as v from "valibot";
import { publicExportDestination } from "./public-export";
import { subscriptionQuery } from "./subscription-preset";

const sourceOfficialUrlSchema = v.object({
  data: v.object({
    officialUrl: v.nullable(
      v.pipe(v.string(), v.url(), v.regex(/^https?:\/\/\S+$/i)),
    ),
  }),
});

const publicCaseCorrectionSchema = v.object({
  slug: v.pipe(v.string(), v.minLength(1), v.maxLength(128)),
  revision: v.pipe(v.number(), v.integer(), v.minValue(1)),
});

export function publicScreenDestinations(
  screen: ScreenViewModel,
  pathname: string,
  data: Readonly<Record<string, unknown>>,
  searchParams: URLSearchParams = new URLSearchParams(),
): Readonly<Record<string, string>> {
  let destinations = {
    ...serverActionDestinations(screen, pathname),
    ...publicSubscriptionDestinations(screen.id, pathname, searchParams),
    ...publicExportDestinations(screen.id, searchParams),
  };
  if (screen.id === "PUB-004") {
    destinations = Object.fromEntries(
      Object.entries(destinations).filter(
        ([actionId]) => actionId !== "request-correction",
      ),
    );
    const correction = publicCaseCorrectionDestination(pathname, data);
    if (correction)
      destinations = { ...destinations, "request-correction": correction };
  }
  if (screen.id !== "PUB-017") return destinations;
  destinations = Object.fromEntries(
    Object.entries(destinations).filter(
      ([actionId]) => actionId !== "view-official",
    ),
  );
  const officialUrl = validatedOfficialSourceUrl(data.getSource);
  return officialUrl
    ? { ...destinations, "view-official": officialUrl }
    : destinations;
}

function publicExportDestinations(
  screenId: string,
  searchParams: URLSearchParams,
): Readonly<Record<string, string>> {
  if (screenId !== "PUB-002" && screenId !== "PUB-003") return {};
  const csv = publicExportDestination(screenId, "CSV", searchParams);
  const jsonl = publicExportDestination(screenId, "JSONL", searchParams);
  return {
    ...(csv ? { "download-csv": csv } : {}),
    ...(jsonl ? { "download-jsonl": jsonl } : {}),
  };
}

function publicSubscriptionDestinations(
  screenId: string,
  pathname: string,
  searchParams: URLSearchParams,
): Readonly<Record<string, string>> {
  if (screenId === "PUB-001")
    return { subscribe: subscriptionDestination("CORRECTIONS") };
  if (screenId === "PUB-003") {
    const contract = urlFilterContractFor(screenId);
    if (!contract) return {};
    const source = new URL(pathname, "https://gurine.invalid");
    for (const name of contract.queryKeys) {
      for (const value of searchParams.getAll(name)) {
        if (value.trim()) source.searchParams.append(name, value);
      }
    }
    return {
      "subscribe-filter": subscriptionDestination("QUERY", {
        query: JSON.stringify(subscriptionQuery(source)),
      }),
    };
  }
  if (screenId === "PUB-004")
    return contextualRecordSubscription(
      "subscribe-case",
      "CASE",
      pathname,
      "cases",
      true,
    );
  if (screenId === "PUB-008")
    return contextualRecordSubscription(
      "subscribe-agency",
      "AGENCY",
      pathname,
      "agencies",
    );
  if (screenId === "PUB-010")
    return contextualRecordSubscription(
      "subscribe-supplier",
      "SUPPLIER",
      pathname,
      "suppliers",
    );
  if (screenId === "PUB-018")
    return { subscribe: subscriptionDestination("CORRECTIONS") };
  return {};
}

function contextualRecordSubscription(
  actionId: string,
  scope: "CASE" | "AGENCY" | "SUPPLIER",
  pathname: string,
  routePrefix: string,
  carriesReturnRoute = false,
): Readonly<Record<string, string>> {
  const pattern = new RegExp(
    `^/${routePrefix}/([A-Za-z0-9._~-]{1,128})/?$`,
    "u",
  );
  const ref = pattern.exec(pathname)?.[1];
  return ref
    ? {
        [actionId]: subscriptionDestination(scope, {
          ref,
          ...(carriesReturnRoute ? { returnTo: `/${routePrefix}/${ref}` } : {}),
        }),
      }
    : {};
}

function subscriptionDestination(
  scope: "QUERY" | "CASE" | "AGENCY" | "SUPPLIER" | "CORRECTIONS",
  context: Readonly<Record<string, string>> = {},
): string {
  const query = new URLSearchParams({ scope, ...context });
  return `/subscribe?${query.toString()}`;
}

function publicCaseCorrectionDestination(
  pathname: string,
  data: Readonly<Record<string, unknown>>,
): string | undefined {
  const match = /^\/cases\/([A-Za-z0-9._~-]+)\/?$/u.exec(pathname);
  if (!match?.[1]) return undefined;
  const result = v.safeParse(publicCaseCorrectionSchema, data.getPublicCase);
  if (!result.success || result.output.slug !== match[1]) return undefined;
  const query = new URLSearchParams({
    case: result.output.slug,
    revision: String(result.output.revision),
  });
  return `/correction-request?${query.toString()}`;
}

function validatedOfficialSourceUrl(response: unknown): string | undefined {
  const result = v.safeParse(sourceOfficialUrlSchema, response);
  return result.success
    ? (result.output.data.officialUrl ?? undefined)
    : undefined;
}
