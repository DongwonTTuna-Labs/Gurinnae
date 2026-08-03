import type { ApiOperation, Operation } from "./screen-contract-catalog";
import {
  arrayValue,
  integerValue,
  type ObjectValue,
  objectValue,
  stringValue,
} from "./screen-contract-values";

export function addendumOperationContractsFrom(
  addendum: ObjectValue,
  resources: ObjectValue,
): Operation[] {
  const values = arrayValue(addendum.operations, "addendum operations");
  const bindings = objectValue(
    resources.operation_bindings,
    "addendum operation bindings",
  );
  const additive = values.map((value, index) => {
    const context = `addendum operations[${index}]`;
    const item = objectValue(value, context);
    const operationId = stringValue(
      item.operation_id,
      `${context}.operation_id`,
    );
    const binding = objectValue(
      bindings[operationId],
      `operation_bindings.${operationId}`,
    );
    const kind = stringValue(item.kind, `${context}.kind`);
    const assurance = stringValue(item.assurance, `${context}.assurance`);
    return {
      operationId,
      status: "READY",
      api: stringValue(item.api, `${context}.api`),
      method: stringValue(item.method, `${context}.method`),
      path: stringValue(item.path, `${context}.path`),
      requestSchema: stringValue(
        binding.request_schema,
        `operation_bindings.${operationId}.request_schema`,
      ),
      responseSchema: stringValue(
        binding.success_schema,
        `operation_bindings.${operationId}.success_schema`,
      ),
      kind,
      mutatesState: kind === "COMMAND",
      successStatus: String(binding.success_status),
      capability:
        item.capability === undefined || item.capability === null
          ? "none"
          : stringValue(item.capability, `${context}.capability`),
      assurance,
      stepUp: assurance === "STEP_UP",
    };
  });
  return uniqueOperations([
    ...additive,
    ...privateBillingOperationsFrom(addendum, resources),
  ]);
}

export function privateBillingApiOperationsFrom(
  addendum: ObjectValue,
  resources: ObjectValue,
): ApiOperation[] {
  return privateBillingOperationsFrom(addendum, resources).map((operation) => ({
    id: operation.operationId,
    api: operation.api,
    method: operation.method,
    path: operation.path,
    responses: {
      [operation.successStatus]: {
        content: {
          "application/json": {
            schema: {
              $ref: `#/components/schemas/${operation.responseSchema}`,
            },
          },
        },
      },
    },
    source: "PRIVATE_BILLING_REGISTRY",
  }));
}

function privateBillingOperationsFrom(
  addendum: ObjectValue,
  resources: ObjectValue,
): Operation[] {
  const privateOperations = objectValue(
    addendum.private_billing_gateway_operations,
    "private billing operations",
  );
  const privateBindings = objectValue(
    resources.private_billing_gateway_operation_bindings,
    "private billing operation bindings",
  );
  const privateRequestSchemas = objectValue(
    resources.private_billing_gateway_request_schemas,
    "private billing request schemas",
  );
  const privateErrorSets = objectValue(
    resources.private_billing_gateway_error_sets,
    "private billing error sets",
  );
  const declaredIds = arrayValue(
    objectValue(resources.set_equality, "set equality")
      .private_billing_gateway_operation_ids,
    "private billing declared operation ids",
  ).map((value, index) =>
    stringValue(value, `private billing declared operation ids[${index}]`),
  );
  const operationIds = Object.keys(privateOperations);
  assertExactKeys(
    operationIds,
    Object.keys(privateBindings),
    "private billing operation/binding set",
  );
  assertExactKeys(
    operationIds,
    Object.keys(privateRequestSchemas),
    "private billing operation/request-schema set",
  );
  assertExactKeys(
    operationIds,
    Object.keys(privateErrorSets),
    "private billing operation/error set",
  );
  assertExactKeys(
    operationIds,
    declaredIds,
    "private billing declared operation set",
  );
  return Object.entries(privateOperations).map(([operationId, value]) =>
    privateBillingOperation(
      operationId,
      value,
      privateBindings[operationId],
      privateRequestSchemas[operationId],
      privateErrorSets[operationId],
    ),
  );
}

function privateBillingOperation(
  operationId: string,
  value: unknown,
  bindingValue: unknown,
  requestSchemaValue: unknown,
  errorSetValue: unknown,
): Operation {
  const context = `private billing operations.${operationId}`;
  const item = objectValue(value, context);
  const binding = objectValue(
    bindingValue,
    `private billing operation bindings.${operationId}`,
  );
  const requestContract = objectValue(
    requestSchemaValue,
    `private billing request schemas.${operationId}`,
  );
  const kind = stringValue(item.operation_kind, `${context}.operation_kind`);
  const entrypoint = objectValue(item.entrypoint, `${context}.entrypoint`);
  const method = stringValue(entrypoint.method, `${context}.entrypoint.method`);
  const path = stringValue(entrypoint.path, `${context}.entrypoint.path`);
  const requestSchema = stringValue(
    item.request_schema,
    `${context}.request_schema`,
  );
  const responseSchema = stringValue(
    item.response_schema,
    `${context}.response_schema`,
  );
  const successStatus = integerValue(
    binding.success_status,
    `private billing operation bindings.${operationId}.success_status`,
  );
  const errors = arrayValue(item.errors, `${context}.errors`).map(
    (error, index) => stringValue(error, `${context}.errors[${index}]`),
  );
  const boundErrors = arrayValue(
    errorSetValue,
    `private billing error sets.${operationId}`,
  ).map((error, index) =>
    stringValue(error, `private billing error sets.${operationId}[${index}]`),
  );
  assertExactKeys(errors, boundErrors, `${operationId} private billing errors`);
  const expectedSource =
    `specs/product/addendum-operation-contracts.yaml#` +
    `private_billing_gateway_operations['${operationId}']`;
  if (
    item.transport !== "PRIVATE_BILLING_GATEWAY_HTTP" ||
    binding.scope !== "PRIVATE_BILLING_GATEWAY" ||
    binding.operation_kind !== kind ||
    binding.source_pointer !== expectedSource ||
    binding.request_schema !== requestSchema ||
    binding.success_schema !== responseSchema ||
    requestContract.name !== requestSchema ||
    requestContract.additional_properties !== false ||
    (entrypoint.success_status !== undefined &&
      entrypoint.success_status !== successStatus)
  )
    throw new Error(`${operationId} private billing operation shape mismatch`);
  if (kind !== "QUERY" && kind !== "COMMAND")
    throw new Error(`${operationId} private billing operation kind is invalid`);
  if (
    !["GET", "POST", "PUT", "PATCH", "DELETE"].includes(method) ||
    !path.startsWith("/internal/")
  )
    throw new Error(`${operationId} private billing entrypoint is invalid`);
  return {
    operationId,
    status: "READY",
    api: "billing-gateway-private",
    method,
    path,
    requestSchema,
    responseSchema,
    kind,
    mutatesState: kind === "COMMAND",
    successStatus: String(successStatus),
    capability: "none",
    assurance: "NONE",
    stepUp: false,
  };
}

function assertExactKeys(
  left: readonly string[],
  right: readonly string[],
  context: string,
): void {
  const leftSorted = sortedUnique(left, `${context} left`);
  const rightSorted = sortedUnique(right, `${context} right`);
  if (JSON.stringify(leftSorted) !== JSON.stringify(rightSorted))
    throw new Error(
      `${context} mismatch: left=${JSON.stringify(leftSorted)} right=${JSON.stringify(rightSorted)}`,
    );
}

function sortedUnique(values: readonly string[], context: string): string[] {
  if (new Set(values).size !== values.length)
    throw new Error(`${context} contains duplicate values`);
  return [...values].sort();
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
