import type {
  PublicCaseLeadViewModel,
  PublicEvidenceViewModel,
  PublicSeoViewModel,
} from "@gurine/ui";
import * as v from "valibot";

const text = v.string();
const nonEmptyText = v.pipe(text, v.trim(), v.minLength(1));
const integer = v.pipe(v.number(), v.integer());
const uuid = v.pipe(text, v.uuid());
const decimal = v.pipe(text, v.regex(/^-?\d+(?:\.\d+)?$/u));
const sha256 = v.pipe(text, v.regex(/^[a-f0-9]{64}$/u));
const dateTime = v.pipe(
  text,
  v.regex(
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u,
  ),
  v.check((value) => !Number.isNaN(Date.parse(value))),
);
const publicState = v.picklist([
  "NEVER_PUBLISHED",
  "PUBLISHED_ANOMALY",
  "PUBLISHED_EXPLAINED",
  "OFFICIALLY_CONFIRMED",
  "CORRECTED",
  "RETRACTED",
  "TEMPORARILY_RESTRICTED",
]);
const currency = v.pipe(text, v.regex(/^[A-Z]{3}$/u));
const httpsUrl = v.pipe(
  text,
  v.url(),
  v.check((value) => {
    const parsed = new URL(value);
    return (
      parsed.protocol === "https:" &&
      parsed.username === "" &&
      parsed.password === ""
    );
  }),
);

const freshness = v.strictObject({
  asOf: dateTime,
  lastSuccessfulFetchAt: v.optional(v.nullable(dateTime)),
  expectedFrequencySeconds: v.optional(v.nullable(integer)),
  lagSeconds: v.optional(v.nullable(integer)),
  status: v.picklist(["CURRENT", "DELAYED", "STALE", "UNKNOWN"]),
});

const publicEvidence = v.strictObject({
  id: uuid,
  title: text,
  evidenceType: text,
  sourceUrl: v.optional(v.nullable(httpsUrl)),
  sourceLocator: text,
  contentSha256: sha256,
  publicExcerpt: v.optional(v.nullable(text)),
  restriction: v.optional(v.nullable(text)),
  documentTitle: v.optional(v.nullable(nonEmptyText)),
  publisher: v.optional(v.nullable(nonEmptyText)),
  publishedAt: v.optional(v.nullable(dateTime)),
  pageAnchor: v.optional(v.nullable(nonEmptyText)),
});

const seo = v.strictObject({
  title: nonEmptyText,
  description: nonEmptyText,
  canonicalUrl: nonEmptyText,
  robots: nonEmptyText,
  structuredDataType: v.optional(v.nullable(text)),
});

const publicCaseResponse = v.strictObject({
  slug: nonEmptyText,
  title: nonEmptyText,
  publicState,
  revision: integer,
  publishedAt: dateTime,
  updatedAt: dateTime,
  summary: nonEmptyText,
  agencyName: v.nullable(nonEmptyText),
  contractName: v.nullable(nonEmptyText),
  amount: v.nullable(v.strictObject({ amount: decimal, currency })),
  nonConclusion: nonEmptyText,
  confirmedFacts: v.array(v.unknown()),
  criticalUnknowns: v.array(v.unknown()),
  partyResponses: v.array(v.unknown()),
  signals: v.array(v.unknown()),
  comparison: v.optional(v.unknown()),
  counterEvidence: v.array(v.unknown()),
  claims: v.array(v.unknown()),
  evidence: v.array(publicEvidence),
  timeline: v.array(v.unknown()),
  corrections: v.array(v.unknown()),
  freshness,
  limitations: v.array(text),
  seo,
});

type PublicCaseResponse = v.InferOutput<typeof publicCaseResponse>;

export type PublicCasePresentation = Readonly<{
  lead: PublicCaseLeadViewModel;
  evidence: readonly PublicEvidenceViewModel[];
  seo: PublicSeoViewModel;
}>;

export function publicCasePresentation(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
  requestUrl: URL,
): PublicCasePresentation | undefined {
  if (screenId !== "PUB-004") return undefined;
  const response = data.getPublicCase;
  if (response === undefined) return undefined;
  const parsed = v.parse(publicCaseResponse, response);
  return {
    lead: leadViewModel(parsed),
    evidence: evidenceViewModels(parsed.evidence),
    seo: seoViewModel(parsed.seo, requestUrl),
  };
}

function leadViewModel(response: PublicCaseResponse): PublicCaseLeadViewModel {
  return {
    slug: response.slug,
    title: response.title,
    publicState: response.publicState,
    revision: response.revision,
    publishedAt: response.publishedAt,
    updatedAt: response.updatedAt,
    freshnessAsOf: response.freshness.asOf,
    agencyName: response.agencyName ?? null,
    contractName: response.contractName ?? null,
    amountLabel: response.amount ? moneyLabel(response.amount) : null,
    summary: response.summary,
    confirmedCount: response.confirmedFacts.length,
    unknownCount: response.criticalUnknowns.length,
    responseCount: response.partyResponses.length,
    nonConclusion: response.nonConclusion,
  };
}

function evidenceViewModels(
  evidence: PublicCaseResponse["evidence"],
): readonly PublicEvidenceViewModel[] {
  return evidence.flatMap((item, index) => {
    const viewModel: PublicEvidenceViewModel = {
      key: `public-evidence-${index + 1}`,
      documentTitle: item.documentTitle ?? null,
      publisher: item.publisher ?? null,
      publishedAt: item.publishedAt ?? null,
      sourceUrl: item.sourceUrl ?? null,
      pageAnchor: item.pageAnchor ?? null,
    };
    return Object.values(viewModel).some(
      (value) => value !== null && value !== viewModel.key,
    )
      ? [viewModel]
      : [];
  });
}

function seoViewModel(
  metadata: PublicCaseResponse["seo"],
  requestUrl: URL,
): PublicSeoViewModel {
  return {
    title: metadata.title,
    description: metadata.description,
    canonicalUrl: sameOriginCanonical(metadata.canonicalUrl, requestUrl),
    robots: robotsValue(metadata.robots),
  };
}

function sameOriginCanonical(value: string, requestUrl: URL): string {
  const canonical = new URL(value, requestUrl.origin);
  if (
    canonical.origin !== requestUrl.origin ||
    !["http:", "https:"].includes(canonical.protocol) ||
    canonical.username !== "" ||
    canonical.password !== ""
  ) {
    throw new Error("PUBLIC_CASE_CANONICAL_NOT_SAME_ORIGIN");
  }
  return canonical.href;
}

function robotsValue(value: string): string {
  const allowed = new Set([
    "follow",
    "index",
    "noarchive",
    "nofollow",
    "noindex",
    "nosnippet",
  ]);
  const tokens = value.split(",").map((token) => token.trim());
  if (tokens.length === 0 || tokens.some((token) => !allowed.has(token))) {
    throw new Error("PUBLIC_CASE_ROBOTS_NOT_ALLOWLISTED");
  }
  return tokens.join(",");
}

function moneyLabel(value: { amount: string; currency: string }): string {
  const [integerPart = "0", decimalPart] = value.amount.split(".");
  const negative = integerPart.startsWith("-");
  const digits = negative ? integerPart.slice(1) : integerPart;
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/gu, ",");
  const amount = `${negative ? "-" : ""}${grouped}${decimalPart ? `.${decimalPart}` : ""}`;
  return value.currency === "KRW"
    ? `₩${amount}`
    : `${value.currency} ${amount}`;
}
