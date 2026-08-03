import { describe, expect, it } from "vitest";
import type { ScreenField } from "./index";
import {
  correctionRequestFormContract,
  datasetExportFormContract,
  namedFormAction,
  publicDatasetCards,
  requestedChangesJson,
  requestedChangesText,
} from "./public-form-presentation";

const datasetFields: readonly ScreenField[] = [
  { name: "datasetId", label: "dataset Id", type: "text", required: true },
  {
    name: "format",
    label: "format",
    type: "text",
    required: true,
    options: ["CSV", "JSONL", "PARQUET"],
  },
  {
    name: "filters",
    label: "filters",
    type: "json",
    required: true,
    value: "{}",
    readonly: true,
  },
  { name: "email", label: "email", type: "text", required: false },
  {
    name: "expiresInSeconds",
    label: "expires In Seconds",
    type: "number",
    required: true,
    value: 86_400,
    readonly: true,
  },
  {
    name: "abuseProof",
    label: "abuse Proof",
    type: "json",
    required: true,
  },
];

const correctionFields: readonly ScreenField[] = [
  {
    name: "locale",
    label: "locale",
    type: "text",
    required: true,
    value: "ko-KR",
    readonly: true,
  },
  {
    name: "caseSlug",
    label: "case Slug",
    type: "text",
    required: false,
    value: "case-100",
    readonly: true,
  },
  {
    name: "publicationRevision",
    label: "publication Revision",
    type: "number",
    required: false,
    value: 3,
    readonly: true,
  },
  {
    name: "abuseProof",
    label: "abuse Proof",
    type: "json",
    required: true,
    challengeAction: "createCorrectionRequestDraft",
  },
  {
    name: "requesterType",
    label: "requester Type",
    type: "text",
    required: true,
  },
  {
    name: "contactEmail",
    label: "contact Email",
    type: "text",
    required: true,
  },
  { name: "summary", label: "summary", type: "text", required: true },
  {
    name: "requestedChanges",
    label: "requested Changes",
    type: "json",
    required: true,
    value: '["금액 정정","발행일 정정"]',
  },
  {
    name: "evidenceDescription",
    label: "evidence Description",
    type: "text",
    required: false,
  },
  {
    name: "expectedVersion",
    label: "expected Version",
    type: "number",
    required: true,
    value: 1,
  },
];

describe("public form presentation", () => {
  it("maps only real dataset DTO values to closed export cards", () => {
    expect(
      publicDatasetCards([
        {
          id: "published-cases",
          title: "공개 사례",
          description: "공개 개정본 고정 사례 데이터",
          format: "JSONL",
          license: "CC-BY-4.0",
          updatedAt: "2026-07-12T00:00:00Z",
        },
      ]),
    ).toEqual([
      {
        id: "published-cases",
        title: "공개 사례",
        description: "공개 개정본 고정 사례 데이터",
        format: "JSONL",
        license: "CC-BY-4.0",
        updatedAt: "2026-07-12T00:00:00Z",
      },
    ]);
    expect(
      publicDatasetCards([
        {
          id: "catalog-native",
          title: "원천 제공 자료",
          description: "카탈로그가 선언한 원본 형식",
          format: "NDJSON.GZ",
          license: "CC-BY-4.0",
          updatedAt: "2026-07-12T00:00:00Z",
        },
      ])[0]?.format,
    ).toBe("NDJSON.GZ");
  });

  it("closes the dataset-export wire fields and server presets", () => {
    expect(datasetExportFormContract(datasetFields)).toMatchObject({
      format: { options: ["CSV", "JSONL", "PARQUET"] },
      filters: { value: "{}", readonly: true },
      expiresInSeconds: { value: 86_400, readonly: true },
      challengeAction: "createDatasetExport",
    });
    expect(() =>
      datasetExportFormContract(
        datasetFields.filter((field) => field.name !== "filters"),
      ),
    ).toThrow("필수 폼 필드 누락: filters");
  });

  it("keeps route presets and hides wire-only correction fields", () => {
    expect(correctionRequestFormContract(correctionFields)).toMatchObject({
      caseSlug: { value: "case-100", readonly: true },
      publicationRevision: { value: 3, readonly: true },
      expectedVersion: { value: 1 },
      challengeAction: "createCorrectionRequestDraft",
    });
    expect(
      correctionRequestFormContract(correctionFields.slice(4)),
    ).toMatchObject({ expectedVersion: { value: 1 } });
  });

  it("serializes one human change per line as the required string array", () => {
    expect(requestedChangesText('["금액 정정","발행일 정정"]')).toBe(
      "금액 정정\n발행일 정정",
    );
    expect(requestedChangesJson("  금액 정정  \n\n발행일 정정\r\n")).toBe(
      '["금액 정정","발행일 정정"]',
    );
    expect(() => requestedChangesText('{"change":"금액"}')).toThrow(
      "문자열 배열",
    );
  });

  it("preserves safe query keys after the named action selector", () => {
    expect(namedFormAction("save-draft", "?caseSlug=case-100&revision=3")).toBe(
      "?/save-draft&caseSlug=case-100&revision=3",
    );
    expect(namedFormAction("save-draft", "?%2Fother=1&case=case-100")).toBe(
      "?/save-draft&case=case-100",
    );
  });
});
