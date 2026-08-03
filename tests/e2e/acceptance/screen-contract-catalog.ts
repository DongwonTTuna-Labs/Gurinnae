import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse } from "yaml";
import {
  addendumOperationContractsFrom,
  privateBillingApiOperationsFrom,
} from "./screen-addendum-operation-contracts";
import {
  arrayValue,
  booleanValue,
  type ObjectValue,
  objectValue,
  stringValue,
} from "./screen-contract-values";

export {
  addendumOperationContractsFrom,
  privateBillingApiOperationsFrom,
} from "./screen-addendum-operation-contracts";
export {
  arrayValue,
  booleanValue,
  objectValue,
  stringValue,
} from "./screen-contract-values";

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
  source: "GENERATED_OPENAPI" | "PRIVATE_BILLING_REGISTRY";
};
const ROOT = resolve(".");
const API_FILES = {
  "control-api": "control-api.openapi.json",
  "identity-api": "identity-api.openapi.json",
  "public-api": "public-api.openapi.json",
  "submission-api": "submission-api.openapi.json",
  "identity-provider": "identity-provider.openapi.json",
} as const;
const METHODS = ["get", "post", "put", "patch", "delete"] as const;

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
  const base = values.map((value, index) => {
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
  return uniqueOperations([...base, ...addendumOperationContracts()]);
}

function addendumOperationContracts(): Operation[] {
  return addendumOperationContractsFrom(
    yamlObject("specs/product/addendum-operation-contracts.yaml"),
    yamlObject("specs/product/addendum-resource-error-contracts.yaml"),
  );
}

function uniqueOperations<T extends { operationId: string }>(values: T[]): T[] {
  const seen = new Set<string>();
  for (const operation of values) {
    if (seen.has(operation.operationId))
      throw new Error(`duplicate operation contract: ${operation.operationId}`);
    seen.add(operation.operationId);
  }
  return values;
}

export function screenDataContracts(): Requirement[] {
  const values = arrayValue(
    yamlObject("specs/ui/screen-data-contracts.yaml").operations,
    "screen-data operations",
  );
  const base = values.map((value, index) =>
    requirement(value, `screen-data operations[${index}]`),
  );
  return uniqueOperations([
    ...base,
    ...addendumOperationContracts().map(
      ({
        operationId,
        status,
        api,
        method,
        path,
        requestSchema,
        responseSchema,
      }) => ({
        operationId,
        status,
        api,
        method,
        path,
        requestSchema,
        responseSchema,
      }),
    ),
  ]);
}

export function apiOperations(): ApiOperation[] {
  const generated = Object.entries(API_FILES).flatMap(([api, filename]) => {
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
            source: "GENERATED_OPENAPI" as const,
          },
        ];
      });
    });
  });
  const privateBilling = privateBillingApiOperationsFrom(
    yamlObject("specs/product/addendum-operation-contracts.yaml"),
    yamlObject("specs/product/addendum-resource-error-contracts.yaml"),
  );
  return composeApiOperations(generated, privateBilling);
}

export function composeApiOperations(
  generated: readonly ApiOperation[],
  privateBilling: readonly ApiOperation[],
): ApiOperation[] {
  const operations = [...generated, ...privateBilling];
  const seen = new Set<string>();
  for (const operation of operations) {
    if (seen.has(operation.id))
      throw new Error(`duplicate API operation ownership: ${operation.id}`);
    seen.add(operation.id);
  }
  return operations;
}
