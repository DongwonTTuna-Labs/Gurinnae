export type PublicCaseLeadViewModel = Readonly<{
  slug: string;
  title: string;
  publicState:
    | "PUBLISHED_ANOMALY"
    | "PUBLISHED_EXPLAINED"
    | "OFFICIALLY_CONFIRMED"
    | "CORRECTED"
    | "RETRACTED"
    | "TEMPORARILY_RESTRICTED";
  revision: number;
  publishedAt: string;
  updatedAt: string;
  freshnessAsOf: string;
  agencyName: string | null;
  contractName: string | null;
  amountLabel: string | null;
  summary: string;
  confirmedCount: number;
  unknownCount: number;
  responseCount: number;
  nonConclusion: string;
}>;

export type PublicEvidenceViewModel = Readonly<{
  key: string;
  documentTitle: string | null;
  publisher: string | null;
  publishedAt: string | null;
  sourceUrl: string | null;
  pageAnchor: string | null;
}>;

export type PublicSeoViewModel = Readonly<{
  title: string;
  description: string;
  openGraphDescription: string;
  canonicalUrl: string;
  robots: string;
}>;
