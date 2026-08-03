import {
  DONATION_INDEPENDENCE_NOTICE,
  FUNDING_SECTION_IDS,
  type FundingDisclosureStatus,
  type FundingSectionId,
  type FundingTransparencyLink,
  type FundingTransparencyViewModel,
} from "@gurine/ui";
import * as v from "valibot";

export const PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE =
  "승인된 공개 비용 계약이 없어 비용 공개 권위가 없습니다. 내부 원가를 추정하거나 공개값으로 바꾸지 않습니다.";
export const PUBLIC_FUNDING_EXPENSE_PRESENTATION_NOTICE =
  "승인된 공개 비용 계약이 없어 비용 자료를 공개하지 않습니다. 내부 원가를 추정하거나 공개값으로 바꾸지 않습니다.";

const text = v.pipe(v.string(), v.minLength(1), v.maxLength(4096));
const timestamp = v.pipe(v.string(), v.isoTimestamp());
const date = v.pipe(v.string(), v.isoDate());
const uuid = v.pipe(v.string(), v.uuid());

const linkSchema = v.strictObject({
  rel: text,
  href: text,
  label: v.optional(text),
});
const sectionSchema = v.strictObject({
  id: v.picklist(FUNDING_SECTION_IDS),
  heading: text,
  body: text,
  links: v.array(linkSchema),
  updatedAt: timestamp,
});
const contentSchema = v.strictObject({
  id: v.strictObject({
    id: v.literal("funding"),
    status: v.picklist(["PUBLISHED", "UNKNOWN"]),
    version: v.pipe(v.number(), v.integer(), v.minValue(1)),
  }),
  version: v.pipe(v.number(), v.integer(), v.minValue(1)),
  status: v.picklist(["AVAILABLE", "UNKNOWN"]),
  updatedAt: timestamp,
  title: text,
  summary: text,
  data: v.strictObject({
    version: v.literal("1.0"),
    title: text,
    updatedAt: timestamp,
    sections: v.array(sectionSchema),
    sourceLinks: v.array(linkSchema),
  }),
  links: v.array(linkSchema),
});
const reportSchema = v.strictObject({
  id: uuid,
  periodStart: date,
  periodEnd: date,
  title: text,
  summary: text,
  publishedAt: timestamp,
  href: text,
});
const reportsPageSchema = v.strictObject({
  items: v.array(reportSchema),
  nextCursor: v.optional(v.string()),
  appliedFilters: v.strictObject({
    periodFrom: v.optional(date),
    periodTo: v.optional(date),
  }),
  asOf: timestamp,
});

export function publicFundingPresentation(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
): FundingTransparencyViewModel | undefined {
  if (screenId !== "PUB-023") return undefined;
  const content = v.safeParse(contentSchema, data.getFundingContent);
  if (!content.success) throw new Error("funding content contract mismatch");
  validateContent(content.output);

  const reportValue = data.listTransparencyReports;
  const reports =
    reportValue === undefined
      ? undefined
      : v.safeParse(reportsPageSchema, reportValue);
  if (reports && !reports.success) {
    throw new Error("funding report list contract mismatch");
  }
  const reportModels = reports ? reports.output.items.map(reportViewModel) : [];
  if (
    duplicate(reportModels.map((report) => report.id)) ||
    (content.output.status === "AVAILABLE" &&
      reports &&
      reportModels.length < 1)
  ) {
    throw new Error("funding report authority mismatch");
  }

  const sections = content.output.data.sections.map((section) => ({
    id: section.id,
    heading: section.heading,
    body:
      section.id === "expenses"
        ? PUBLIC_FUNDING_EXPENSE_PRESENTATION_NOTICE
        : section.body,
    status: sectionStatus(
      content.output.status,
      section.id,
      reports !== undefined,
    ),
    updatedAt: section.updatedAt,
    links: section.links
      .filter((link) => link.rel !== "download")
      .map(publicLink),
  }));
  return {
    status: content.output.status,
    summary: content.output.summary,
    updatedAt: content.output.updatedAt,
    sections,
    reports: reportModels,
  };
}

function validateContent(content: v.InferOutput<typeof contentSchema>): void {
  const sectionIds = content.data.sections.map((section) => section.id);
  if (
    content.version !== content.id.version ||
    content.updatedAt !== content.data.updatedAt ||
    content.data.sections.some(
      (section) => section.updatedAt !== content.updatedAt,
    ) ||
    sectionIds.some((id, index) => id !== FUNDING_SECTION_IDS[index]) ||
    sectionIds.length !== FUNDING_SECTION_IDS.length ||
    content.data.sections[0]?.body !== DONATION_INDEPENDENCE_NOTICE ||
    content.data.sections[2]?.body !==
      PUBLIC_FUNDING_EXPENSE_AUTHORITY_NOTICE ||
    (content.status === "AVAILABLE" && content.id.status !== "PUBLISHED") ||
    (content.status === "UNKNOWN" && content.id.status !== "UNKNOWN")
  ) {
    throw new Error("funding content binding mismatch");
  }
  for (const link of [
    ...content.links,
    ...content.data.sourceLinks,
    ...content.data.sections.flatMap((section) => section.links),
  ]) {
    if (!safePublicHref(link.href)) {
      throw new Error("funding content link is unsafe");
    }
  }
}

function reportViewModel(report: v.InferOutput<typeof reportSchema>) {
  const canonicalHref = `/v1/transparency-reports/${report.id}/download`;
  if (report.periodStart >= report.periodEnd || report.href !== canonicalHref) {
    throw new Error("funding report binding mismatch");
  }
  const path = `/downloads/transparency-reports/${report.id}`;
  return {
    id: report.id,
    periodStart: report.periodStart,
    periodEnd: report.periodEnd,
    title: report.title,
    summary: report.summary,
    publishedAt: report.publishedAt,
    jsonDownloadHref: `${path}?format=JSON`,
    csvDownloadHref: `${path}?format=CSV`,
  };
}

function publicLink(
  link: v.InferOutput<typeof linkSchema>,
): FundingTransparencyLink {
  if (!link.label || !safePublicHref(link.href)) {
    throw new Error("funding link is unsafe");
  }
  return { label: link.label, href: link.href };
}

function sectionStatus(
  overall: "AVAILABLE" | "UNKNOWN",
  sectionId: FundingSectionId,
  reportListAvailable: boolean,
): FundingDisclosureStatus {
  if (sectionId === "principles") return "AVAILABLE";
  if (sectionId === "expenses") return "UNAVAILABLE";
  if (sectionId === "reports" && !reportListAvailable) return "UNAVAILABLE";
  return overall;
}

function safePublicHref(value: string): boolean {
  if (
    value.length < 1 ||
    value.length > 2048 ||
    value.includes("\\") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    return false;
  }
  if (value.startsWith("/")) return !value.startsWith("//");
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      url.username === "" &&
      url.password === "" &&
      url.hostname !== ""
    );
  } catch {
    return false;
  }
}

function duplicate(values: readonly string[]): boolean {
  return new Set(values).size !== values.length;
}
