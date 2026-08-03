import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";
import { describe, expect, it } from "vitest";
import operationSamples from "../../../verification/generated-operation-samples.json";
import {
  indexOperations,
  type OpenApiDocument,
  operationFields,
} from "../../config/src/screen-runtime";
import {
  ENUM_PRESENTATION_LABELS,
  forbiddenRawEnumValues,
  hasEnumPresentation,
  isEnumCandidate,
  presentEnumValue,
  retainedTechnicalEnumValues,
} from "./enum-presentation";
import {
  SCREEN_PROJECTION_BINDINGS,
  type ScreenProjectionBinding,
} from "./generated-screen-projections";
import { privateBillingScreenOperationFields } from "./private-billing-screen-operation.test-support";
import {
  PRE_R6E_ENUM_LABEL_GAPS,
  R6E_OPERATION_IDS,
  R6E_RUNTIME_ONLY_ENUM_LABEL_GAPS,
  R6E_SCREEN_OPERATION_IDS,
  r6eOperationLabelContract,
} from "./r6e-label-contract.test-support";

const mockDirectory = fileURLToPath(
  new URL("../../../tests/e2e/support/", import.meta.url),
);
const screenDataContractsPath = fileURLToPath(
  new URL("../../../specs/ui/screen-data-contracts.yaml", import.meta.url),
);
const screenCatalogPath = fileURLToPath(
  new URL("../../../specs/ui/screen-catalog.yaml", import.meta.url),
);

function screenOperationIds(): Set<string> {
  const catalog = readFileSync(screenCatalogPath, "utf8");
  const result = new Set(
    [...catalog.matchAll(/^\s*(?:-\s*)?operation_id:\s*([^\s#]+)/gmu)].flatMap(
      (match) => (match[1] ? [match[1]] : []),
    ),
  );
  const bindings: Readonly<
    Record<string, Readonly<Record<string, ScreenProjectionBinding>>>
  > = SCREEN_PROJECTION_BINDINGS;
  for (const screen of Object.values(bindings))
    for (const binding of Object.values(screen))
      result.add(binding.operationId);
  return result;
}

function screenOperationEnumValues(): Set<string> {
  const documents = [
    "public-api",
    "submission-api",
    "identity-provider",
    "control-api",
  ].map(
    (api) =>
      JSON.parse(
        readFileSync(
          fileURLToPath(
            new URL(
              `../../../specs/generated/${api}.openapi.json`,
              import.meta.url,
            ),
          ),
          "utf8",
        ),
      ) as OpenApiDocument,
  );
  const operations = indexOperations(documents);
  const result = new Set<string>();
  const operationIds = screenOperationIds();
  const privateFields = privateBillingScreenOperationFields(operationIds);
  for (const operationId of operationIds) {
    const operation = operations.get(operationId);
    const fields = operation
      ? operationFields(operation, {})
      : privateFields.get(operationId);
    if (!fields) throw new Error(`화면 API 작업 계약 누락: ${operationId}`);
    for (const field of fields)
      for (const value of field.options ?? [])
        if (isEnumCandidate(value)) result.add(value);
  }
  return result;
}

function collectJsonEnums(value: unknown, result: Set<string>): void {
  if (typeof value === "string") {
    if (isEnumCandidate(value)) result.add(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectJsonEnums(item, result);
    return;
  }
  if (typeof value !== "object" || value === null) return;
  for (const item of Object.values(value)) collectJsonEnums(item, result);
}

function requiredEnumValues(): Set<string> {
  const result = new Set<string>();
  collectJsonEnums(operationSamples, result);
  const screenDataContracts = readFileSync(screenDataContractsPath, "utf8");
  for (const match of screenDataContracts.matchAll(
    /^\s*type:\s*enum:([^\s#]+)\s*$/gmu,
  )) {
    for (const value of (match[1] ?? "").split(",")) {
      if (isEnumCandidate(value)) result.add(value);
    }
  }
  for (const file of readdirSync(mockDirectory)
    .filter((name) => /^mock-api.*\.ts$/u.test(name))
    .sort()) {
    const source = ts.createSourceFile(
      file,
      readFileSync(`${mockDirectory}/${file}`, "utf8"),
      ts.ScriptTarget.Latest,
      true,
    );
    const visit = (node: ts.Node): void => {
      if (
        (ts.isStringLiteral(node) ||
          ts.isNoSubstitutionTemplateLiteral(node)) &&
        isEnumCandidate(node.text)
      )
        result.add(node.text);
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return result;
}

describe("closed Korean enum presentation", () => {
  it("covers every enum option rendered by the 95-screen operation forms", () => {
    const required = screenOperationEnumValues();
    expect(required.size).toBeGreaterThan(0);
    expect(
      [...required].filter((value) => !hasEnumPresentation(value)),
    ).toEqual([]);
  });

  it("pins the exact pre-R6e UI contract, sample, and mock enum gaps", () => {
    const required = requiredEnumValues();
    expect(required.size).toBeGreaterThan(0);
    expect(
      [...required].filter((value) => !hasEnumPresentation(value)).sort(),
    ).toEqual(PRE_R6E_ENUM_LABEL_GAPS);
  });

  it("covers the exact R6e request and success-response enum set", () => {
    const contract = r6eOperationLabelContract();
    expect(contract.operationIds).toEqual(R6E_OPERATION_IDS);
    expect(contract.labelOperationIds).toEqual(R6E_SCREEN_OPERATION_IDS);
    expect(contract.enums.size).toBeGreaterThan(0);
    expect(
      [...contract.enums].filter((value) => !hasEnumPresentation(value)).sort(),
    ).toEqual([]);
    expect(
      [...contract.runtimeOnlyEnums]
        .filter((value) => !hasEnumPresentation(value))
        .sort(),
    ).toEqual(R6E_RUNTIME_ONLY_ENUM_LABEL_GAPS);
  });

  it("fails closed for an unregistered uppercase enum", () => {
    expect(() => presentEnumValue("NEW_UNREGISTERED_STATE")).toThrowError(
      "한국어 enum 표현 계약 누락: NEW_UNREGISTERED_STATE",
    );
  });

  it("exposes only translated raw values to the UI smell gate", () => {
    expect([...forbiddenRawEnumValues].sort()).toEqual(
      Object.keys(ENUM_PRESENTATION_LABELS).sort(),
    );
    expect(
      [...retainedTechnicalEnumValues].filter((value) =>
        forbiddenRawEnumValues.has(value),
      ),
    ).toEqual([]);
    expect(presentEnumValue("PUBLISHED_ANOMALY")).toBe("이상 징후 게시됨");
    expect(presentEnumValue("REGION")).toBe("지역");
    expect(presentEnumValue("TASK")).toBe("작업");
    expect(presentEnumValue("SAME_LOGICAL_EVENT")).toBe("동일 사건 흐름");
    expect(presentEnumValue("KRW")).toBe("KRW");
  });
});
