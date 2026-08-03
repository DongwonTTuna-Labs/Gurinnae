import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect } from "@playwright/test";
import { parse } from "yaml";

type ObjectValue = Record<string, unknown>;
type Section = {
  id: string;
  component: string;
  order: number;
  complete: boolean;
};
type Requirement = {
  operationId: string;
  status: string;
  api: string;
  method: string;
  path: string;
  requestSchema: string;
  responseSchema: string;
};
type Action = {
  id: string;
  capability: string;
  operationId?: string;
  interaction: string;
  assurance: string;
  stepUp: boolean;
  confirmation: boolean;
  localOnly: boolean;
};
export type Screen = {
  id: string;
  surface: string;
  route: string;
  archetype: string;
  users: string[];
  job: string;
  questions: string[];
  sections: Section[];
  actions: Action[];
  requirements: Requirement[];
  analytics: string[];
  releaseScope: string;
  implementationStatus: string;
  visualStatus: string;
  testPrefix: string;
  aboveFold: string[];
  primaryActionId: string;
  implementationFileCount: number;
  keyOrder: string[];
  forbiddenKeyPaths: string[];
};
export type Operation = Requirement & {
  kind: string;
  mutatesState: boolean;
  successStatus: string;
  capability: string;
  assurance: string;
  stepUp: boolean;
};
export type ApiOperation = {
  id: string;
  api: string;
  method: string;
  path: string;
  responses: ObjectValue;
};
const ROOT = resolve(".");
const API_FILES = {
  "control-api": "control-api.openapi.json",
  "public-api": "public-api.openapi.json",
  "submission-api": "submission-api.openapi.json",
  "identity-provider": "identity-provider.openapi.json",
} as const;
const METHODS = ["get", "post", "put", "patch", "delete"] as const;

function isObjectValue(value: unknown): value is ObjectValue {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function objectValue(value: unknown, context: string): ObjectValue {
  if (!isObjectValue(value)) throw new Error(`${context} must be an object`);
  return value;
}

export function arrayValue(value: unknown, context: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${context} must be an array`);
  return value;
}

export function stringValue(value: unknown, context: string): string {
  if (typeof value !== "string" || value.trim() === "")
    throw new Error(`${context} must be a non-empty string`);
  return value;
}

export function booleanValue(value: unknown, context: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${context} must be boolean`);
  return value;
}

export function stringList(value: unknown, context: string): string[] {
  return arrayValue(value, context).map((entry, index) =>
    stringValue(entry, `${context}[${index}]`),
  );
}

function optionalString(value: unknown, context: string): string | undefined {
  return value === undefined ? undefined : stringValue(value, context);
}

export function yamlObject(path: string): ObjectValue {
  const raw: unknown = parse(readFileSync(resolve(ROOT, path), "utf8"));
  return objectValue(raw, path);
}

function jsonObject(path: string): ObjectValue {
  const raw: unknown = JSON.parse(readFileSync(resolve(ROOT, path), "utf8"));
  return objectValue(raw, path);
}

function forbiddenKeys(value: unknown, path: string): string[] {
  if (Array.isArray(value))
    return value.flatMap((entry, index) =>
      forbiddenKeys(entry, `${path}[${index}]`),
    );
  if (typeof value !== "object" || value === null) return [];
  return Object.entries(value).flatMap(([key, entry]) => [
    ...(/milestone|deferred/i.test(key) ? [`${path}.${key}`] : []),
    ...forbiddenKeys(entry, `${path}.${key}`),
  ]);
}

function section(value: unknown, context: string): Section {
  const item = objectValue(value, context);
  return {
    id: stringValue(item.id, `${context}.id`),
    component: stringValue(item.component, `${context}.component`),
    order: Number(item.order),
    complete: [item.title, item.purpose].every(
      (entry) => typeof entry === "string" && entry.trim() !== "",
    ),
  };
}

function requirement(value: unknown, context: string): Requirement {
  const item = objectValue(value, context);
  return {
    operationId: stringValue(item.operation_id, `${context}.operation_id`),
    status: stringValue(item.status, `${context}.status`),
    api: stringValue(item.api, `${context}.api`),
    method: stringValue(item.method, `${context}.method`),
    path: stringValue(item.path, `${context}.path`),
    requestSchema: stringValue(
      item.request_schema,
      `${context}.request_schema`,
    ),
    responseSchema: stringValue(
      item.response_schema,
      `${context}.response_schema`,
    ),
  };
}

function action(value: unknown, context: string): Action {
  const item = objectValue(value, context);
  const operationId = optionalString(
    item.operation_id,
    `${context}.operation_id`,
  );
  return {
    id: stringValue(item.id, `${context}.id`),
    capability: stringValue(item.capability, `${context}.capability`),
    ...(operationId ? { operationId } : {}),
    interaction: stringValue(
      item.interaction_kind,
      `${context}.interaction_kind`,
    ),
    assurance: stringValue(item.assurance_level, `${context}.assurance_level`),
    stepUp: booleanValue(item.step_up_required, `${context}.step_up_required`),
    confirmation: booleanValue(
      item.confirmation_required,
      `${context}.confirmation_required`,
    ),
    localOnly: item.local_only === true,
  };
}

export function catalogScreens(): Screen[] {
  const values = arrayValue(
    yamlObject("specs/ui/screen-catalog.yaml").screens,
    "screens",
  );
  return values.map((value, index) => {
    const context = `screens[${index}]`;
    const item = objectValue(value, context);
    return {
      id: stringValue(item.id, `${context}.id`),
      surface: stringValue(item.surface, `${context}.surface`),
      route: stringValue(item.route, `${context}.route`),
      archetype: stringValue(item.archetype, `${context}.archetype`),
      users: stringList(item.primary_users, `${context}.primary_users`),
      job: stringValue(item.primary_job, `${context}.primary_job`),
      questions: stringList(item.user_questions, `${context}.user_questions`),
      sections: arrayValue(item.sections, `${context}.sections`).map(
        (entry, sectionIndex) =>
          section(entry, `${context}.sections[${sectionIndex}]`),
      ),
      actions: arrayValue(item.actions, `${context}.actions`).map(
        (entry, actionIndex) =>
          action(entry, `${context}.actions[${actionIndex}]`),
      ),
      requirements: arrayValue(
        item.data_requirements,
        `${context}.data_requirements`,
      ).map((entry, requirementIndex) =>
        requirement(entry, `${context}.data_requirements[${requirementIndex}]`),
      ),
      analytics: stringList(
        item.analytics_events,
        `${context}.analytics_events`,
      ),
      releaseScope: stringValue(item.release_scope, `${context}.release_scope`),
      implementationStatus: stringValue(
        item.implementation_status,
        `${context}.implementation_status`,
      ),
      visualStatus: stringValue(item.visual_status, `${context}.visual_status`),
      testPrefix: stringValue(item.test_id_prefix, `${context}.test_id_prefix`),
      aboveFold: stringList(
        item.above_fold_order,
        `${context}.above_fold_order`,
      ),
      primaryActionId: stringValue(
        item.primary_action_id,
        `${context}.primary_action_id`,
      ),
      implementationFileCount: Object.keys(
        objectValue(
          item.implementation_files,
          `${context}.implementation_files`,
        ),
      ).length,
      keyOrder: Object.keys(item),
      forbiddenKeyPaths: forbiddenKeys(item, context),
    };
  });
}

export function operationContracts(): Operation[] {
  const values = arrayValue(
    yamlObject("specs/api/operation-contracts.yaml").operations,
    "operations",
  );
  return values.map((value, index) => {
    const context = `operations[${index}]`;
    const item = objectValue(value, context);
    return {
      ...requirement({ ...item, status: item.status }, context),
      kind: stringValue(item.operation_kind, `${context}.operation_kind`),
      mutatesState: booleanValue(
        item.mutates_state,
        `${context}.mutates_state`,
      ),
      successStatus: String(item.success_status),
      capability: stringValue(item.capability, `${context}.capability`),
      assurance: stringValue(
        item.assurance_level,
        `${context}.assurance_level`,
      ),
      stepUp: booleanValue(
        item.step_up_required,
        `${context}.step_up_required`,
      ),
    };
  });
}

function screenDataContracts(): Requirement[] {
  const values = arrayValue(
    yamlObject("specs/ui/screen-data-contracts.yaml").operations,
    "screen-data operations",
  );
  return values.map((value, index) =>
    requirement(value, `screen-data operations[${index}]`),
  );
}

export function apiOperations(): ApiOperation[] {
  return Object.entries(API_FILES).flatMap(([api, filename]) => {
    const document = jsonObject(`specs/generated/${filename}`);
    const paths = objectValue(document.paths, `${filename}.paths`);
    return Object.entries(paths).flatMap(([path, rawPath]) => {
      const pathItem = objectValue(rawPath, `${filename}.paths.${path}`);
      return METHODS.flatMap((method) => {
        if (pathItem[method] === undefined) return [];
        const operation = objectValue(
          pathItem[method],
          `${filename}:${method}:${path}`,
        );
        return [
          {
            id: stringValue(
              operation.operationId,
              `${filename}:${method}:${path}.operationId`,
            ),
            api,
            method: method.toUpperCase(),
            path,
            responses: objectValue(
              operation.responses,
              `${filename}:${method}:${path}.responses`,
            ),
          },
        ];
      });
    });
  });
}

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
  expect(requirements, "screen data requirements").toHaveLength(226);
  expect(screenData, "screen-data operation contracts").toHaveLength(212);
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
