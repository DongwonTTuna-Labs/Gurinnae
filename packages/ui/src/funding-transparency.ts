import { presentProjectionValue } from "./projection-value";

export const FUNDING_SECTION_IDS = [
  "principles",
  "income",
  "expenses",
  "donors",
  "conflicts",
  "reports",
] as const;

export type FundingSectionId = (typeof FUNDING_SECTION_IDS)[number];
export type FundingDisclosureStatus = "AVAILABLE" | "UNKNOWN" | "UNAVAILABLE";

export type FundingTransparencyLink = Readonly<{
  label: string;
  href: string;
}>;

export type FundingTransparencySection = Readonly<{
  id: FundingSectionId;
  heading: string;
  body: string;
  status: FundingDisclosureStatus;
  updatedAt: string;
  links: readonly FundingTransparencyLink[];
}>;

export type FundingTransparencyReport = Readonly<{
  id: string;
  periodStart: string;
  periodEnd: string;
  title: string;
  summary: string;
  publishedAt: string;
  jsonDownloadHref: string;
  csvDownloadHref: string;
}>;

export type FundingTransparencyViewModel = Readonly<{
  status: "AVAILABLE" | "UNKNOWN";
  summary: string;
  updatedAt: string;
  sections: readonly FundingTransparencySection[];
  reports: readonly FundingTransparencyReport[];
}>;

export function fundingDisclosureStatusLabel(
  status: FundingDisclosureStatus,
): string {
  switch (status) {
    case "AVAILABLE":
      return "공개됨";
    case "UNKNOWN":
      return "확인 불가";
    case "UNAVAILABLE":
      return "공개 자료 없음";
  }
}

export function fundingTimestampLabel(value: string): string {
  const presented = presentProjectionValue("updatedAt", value);
  if (presented?.kind !== "scalar" || presented.valueKind !== "date") {
    return "확인 불가";
  }
  return presented.title ?? presented.text;
}
