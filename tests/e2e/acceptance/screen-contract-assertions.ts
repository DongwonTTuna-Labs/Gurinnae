import { expect } from "@playwright/test";
import {
  type ApiOperation,
  apiOperations,
  catalogScreens,
  type Operation,
  objectValue,
  operationContracts,
  screenDataContracts,
} from "./screen-contract-catalog";

export {
  type ApiOperation,
  apiOperations,
  arrayValue,
  booleanValue,
  catalogScreens,
  type Operation,
  objectValue,
  operationContracts,
  type Screen,
  stringList,
  stringValue,
  yamlObject,
} from "./screen-contract-catalog";

export function assertUnique(values: string[], context: string): void {
  expect(new Set(values).size, context).toBe(values.length);
}

export function operationMap(operations: Operation[]): Map<string, Operation> {
  assertUnique(
    operations.map((operation) => operation.operationId),
    "operation ids unique",
  );
  return new Map(
    operations.map((operation) => [operation.operationId, operation]),
  );
}

export function assertResponse(
  operation: ApiOperation,
  expectedSchema: string,
  context: string,
  successStatus?: string,
): void {
  const candidates = Object.entries(operation.responses).filter(([status]) =>
    successStatus ? status === successStatus : /^[23]\d\d$/.test(status),
  );
  expect(candidates.length, `${context} success response`).toBeGreaterThan(0);
  const refs = candidates.flatMap(([status, rawResponse]) => {
    const response = objectValue(rawResponse, `${context}.responses.${status}`);
    const content = response.content;
    if (content === undefined) return [];
    const media = objectValue(
      content,
      `${context}.responses.${status}.content`,
    );
    const json = media["application/json"];
    if (json === undefined) return [];
    const schema = objectValue(
      objectValue(json, `${context}.responses.${status}.json`).schema,
      `${context}.responses.${status}.schema`,
    );
    return typeof schema.$ref === "string" ? [schema.$ref] : [];
  });
  if (refs.length > 0) {
    expect(refs, `${context} response schema`).toContain(
      `#/components/schemas/${expectedSchema}`,
    );
    return;
  }
  const redirects = candidates.some(([status, rawResponse]) => {
    const response = objectValue(rawResponse, `${context}.responses.${status}`);
    const headers = response.headers;
    return (
      status === "303" &&
      headers !== undefined &&
      "Location" in objectValue(headers, context)
    );
  });
  expect(redirects, `${context} bodyless redirect contract`).toBe(true);
}

export function assertDataRequirements(): void {
  const requirements = catalogScreens().flatMap(
    (screen) => screen.requirements,
  );
  const operations = operationContracts();
  const byId = operationMap(operations);
  const screenData = screenDataContracts();
  assertUnique(
    screenData.map((operation) => operation.operationId),
    "screen-data operation ids unique",
  );
  const screenDataById = new Map(
    screenData.map((operation) => [operation.operationId, operation]),
  );
  const apiIndex = apiOperations();
  expect(requirements, "screen data requirements").toHaveLength(225);
  expect(screenData, "screen-data operation contracts").toHaveLength(264);
  expect(
    screenData.map((operation) => operation.operationId).sort(),
    "operation-contracts ↔ screen-data ids",
  ).toEqual(operations.map((operation) => operation.operationId).sort());
  for (const operation of operations) {
    const dataContract = screenDataById.get(operation.operationId);
    expect(
      dataContract,
      `${operation.operationId} screen-data contract`,
    ).toBeDefined();
    if (!dataContract) continue;
    for (const key of [
      "status",
      "api",
      "method",
      "path",
      "requestSchema",
      "responseSchema",
    ] as const)
      expect(
        dataContract[key],
        `${operation.operationId} screen-data ${key}`,
      ).toBe(operation[key]);
  }
  for (const requirement of requirements) {
    expect(requirement.status, `${requirement.operationId} readiness`).toBe(
      "READY",
    );
    const operation = byId.get(requirement.operationId);
    const dataContract = screenDataById.get(requirement.operationId);
    expect(
      operation,
      `${requirement.operationId} operation contract`,
    ).toBeDefined();
    expect(
      dataContract,
      `${requirement.operationId} screen-data contract`,
    ).toBeDefined();
    if (!operation || !dataContract) continue;
    for (const key of [
      "api",
      "method",
      "path",
      "requestSchema",
      "responseSchema",
    ] as const) {
      expect(requirement[key], `${requirement.operationId} ${key}`).toBe(
        operation[key],
      );
      expect(
        requirement[key],
        `${requirement.operationId} screen-data ${key}`,
      ).toBe(dataContract[key]);
    }
    const matches = apiIndex.filter(
      (entry) => entry.id === requirement.operationId,
    );
    expect(
      matches,
      `${requirement.operationId} OpenAPI uniqueness`,
    ).toHaveLength(1);
    const match = matches[0];
    if (!match) continue;
    expect(
      [match.api, match.method, match.path],
      `${requirement.operationId} OpenAPI route`,
    ).toEqual([requirement.api, requirement.method, requirement.path]);
    assertResponse(
      match,
      requirement.responseSchema,
      requirement.operationId,
      operation.successStatus,
    );
  }
  // Contract and mock schemas cannot prove that a real backend or live dataset is ready.
}

export function assertFinalDelivery(): void {
  for (const screen of catalogScreens()) {
    expect(screen.releaseScope, `${screen.id} release scope`).toBe("FINAL");
    expect(
      screen.implementationStatus,
      `${screen.id} implementation status`,
    ).toBe("REQUIRED_COMPLETE");
    expect(screen.visualStatus, `${screen.id} visual status`).toBe("FINAL");
    expect(
      screen.forbiddenKeyPaths,
      `${screen.id} milestone/deferred keys`,
    ).toEqual([]);
  }
}
