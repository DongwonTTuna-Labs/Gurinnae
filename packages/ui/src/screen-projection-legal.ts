import { explicitKoreanContextLabel, fieldLabel } from "./field-labels";
import {
  type ApprovedRetentionScheduleRow,
  parseApprovedRetentionSchedules,
} from "./retention-schedule";
import type { SpecializedProjection } from "./screen-projection-specialized-types";

type LegalProjectionContract = Readonly<{
  operationId: "getPrivacyPolicy" | "getTerms";
  sectionIds: readonly string[];
  retentionScheduleSectionId: "retention" | "data";
}>;

const LEGAL_PROJECTION_CONTRACTS: Readonly<
  Record<string, LegalProjectionContract>
> = {
  "PUB-031": {
    operationId: "getPrivacyPolicy",
    sectionIds: [
      "controller",
      "categories",
      "purposes",
      "retention",
      "processors",
      "rights",
      "security",
      "history",
    ],
    retentionScheduleSectionId: "retention",
  },
  "PUB-032": {
    operationId: "getTerms",
    sectionIds: [
      "service",
      "content",
      "data",
      "prohibited",
      "liability",
      "changes",
    ],
    retentionScheduleSectionId: "data",
  },
};

export function legalDocumentFields(
  screenId: string,
  sectionId: string,
  data: Readonly<Record<string, unknown>>,
): SpecializedProjection | null {
  const contract = LEGAL_PROJECTION_CONTRACTS[screenId];
  if (!contract?.sectionIds.includes(sectionId)) return null;
  const response = data[contract.operationId];
  if (response === undefined) return null;
  const parsed = parseDocument(response, contract);
  if (!parsed)
    return {
      fields: [
        {
          name: sectionId,
          label: fieldLabel(sectionId),
          value: null,
          known: false,
          source: `${contract.operationId}.data.sections[${sectionId}]`,
        },
        {
          name: "status",
          label: "현재 상태",
          value: null,
          known: false,
          source: `${contract.operationId}.status`,
        },
      ],
      blocked: true,
    };
  const section = parsed.sections.get(sectionId);
  if (!section) return null;
  return {
    fields: [
      {
        name: sectionId,
        label: explicitKoreanContextLabel(section.heading),
        value: section.body,
        known: true,
        source: `${contract.operationId}.data.sections[${sectionId}].body`,
      },
      {
        name: "status",
        label: "현재 상태",
        value: parsed.status,
        known: true,
        source: `${contract.operationId}.status`,
      },
    ],
    blocked: false,
    ...(sectionId === contract.retentionScheduleSectionId
      ? { retentionSchedules: parsed.retentionSchedules }
      : {}),
  };
}

type ParsedLegalDocument = Readonly<{
  status: string;
  sections: ReadonlyMap<string, { heading: string; body: string }>;
  retentionSchedules: readonly ApprovedRetentionScheduleRow[];
}>;

function parseDocument(
  value: unknown,
  contract: LegalProjectionContract,
): ParsedLegalDocument | null {
  const response = record(value);
  const payload = record(response?.data);
  const status = nonEmptyText(response?.status);
  const payloadStatus = nonEmptyText(payload?.status);
  const sections = Array.isArray(payload?.sections) ? payload.sections : null;
  if (
    !response ||
    !payload ||
    status !== "PUBLISHED" ||
    status !== payloadStatus ||
    !sections ||
    !exactPayloadShape(payload)
  )
    return null;
  if (sections.length !== contract.sectionIds.length) return null;
  const allowed = new Set(contract.sectionIds);
  const byId = new Map<string, { heading: string; body: string }>();
  for (const value of sections) {
    const section = record(value);
    const id = nonEmptyText(section?.id);
    const heading = nonEmptyText(section?.heading);
    const body = nonEmptyText(section?.body);
    if (!id || !heading || !body || !allowed.has(id) || byId.has(id))
      return null;
    byId.set(id, { heading, body });
  }
  if (contract.sectionIds.some((id) => !byId.has(id))) return null;
  const retentionSchedules = parseApprovedRetentionSchedules(
    payload.retentionSchedules,
  );
  if (!retentionSchedules) return null;
  return {
    status,
    sections: byId,
    retentionSchedules,
  };
}

function exactPayloadShape(
  payload: Readonly<Record<string, unknown>>,
): boolean {
  const expected = ["retentionSchedules", "sections", "status"];
  const actual = Object.keys(payload).sort();
  return (
    actual.length === expected.length &&
    expected.every((key, index) => actual[index] === key)
  );
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function nonEmptyText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}
