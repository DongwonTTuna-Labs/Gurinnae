import { readFileSync } from "node:fs";
import { parse } from "yaml";

type ObjectValue = Record<string, unknown>;
export type PrivateBillingScreenField = Readonly<{
  name: string;
  options: readonly string[];
}>;

function objectValue(value: unknown, context: string): ObjectValue {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error(`${context} must be an object`);
  return value as ObjectValue;
}

function stringValue(value: unknown, context: string): string {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`${context} must be a non-empty string`);
  return value;
}

function yamlObject(relativePath: string): ObjectValue {
  const value: unknown = parse(
    readFileSync(new URL(`../../../${relativePath}`, import.meta.url), "utf8"),
  );
  return objectValue(value, relativePath);
}

function enumOptions(type: string): readonly string[] {
  const match = type.match(/^enum<([^<>]+)>$/u);
  return match?.[1]?.split("|") ?? [];
}

export function privateBillingScreenOperationFields(
  operationIds: ReadonlySet<string>,
): ReadonlyMap<string, readonly PrivateBillingScreenField[]> {
  const operations = objectValue(
    yamlObject("specs/product/addendum-operation-contracts.yaml")
      .private_billing_gateway_operations,
    "private billing operations",
  );
  const resources = yamlObject(
    "specs/product/addendum-resource-error-contracts.yaml",
  );
  const bindings = objectValue(
    resources.private_billing_gateway_operation_bindings,
    "private billing operation bindings",
  );
  const requestSchemas = objectValue(
    resources.private_billing_gateway_request_schemas,
    "private billing request schemas",
  );
  if (
    JSON.stringify(Object.keys(operations).sort()) !==
    JSON.stringify(Object.keys(bindings).sort())
  )
    throw new Error("private billing operation/binding set mismatch");

  const result = new Map<string, readonly PrivateBillingScreenField[]>();
  for (const operationId of operationIds) {
    if (!operationId.startsWith("private.")) continue;
    const operation = objectValue(
      operations[operationId],
      `private billing operations.${operationId}`,
    );
    const binding = objectValue(
      bindings[operationId],
      `private billing operation bindings.${operationId}`,
    );
    const requestSchema = stringValue(
      operation.request_schema,
      `${operationId}.request_schema`,
    );
    if (
      binding.scope !== "PRIVATE_BILLING_GATEWAY" ||
      binding.operation_kind !== operation.operation_kind ||
      binding.request_schema !== requestSchema ||
      binding.success_schema !== operation.response_schema
    )
      throw new Error(
        `${operationId} private billing operation shape mismatch`,
      );
    const schema = objectValue(
      requestSchemas[operationId],
      `private billing request schemas.${operationId}`,
    );
    if (schema.name !== requestSchema || schema.additional_properties !== false)
      throw new Error(`${operationId} private billing request schema mismatch`);
    const fields = objectValue(
      schema.fields,
      `private billing request schemas.${operationId}.fields`,
    );
    result.set(
      operationId,
      Object.entries(fields).map(([name, type]) => {
        const fieldType = stringValue(type, `${operationId}.${name}`);
        return { name, options: enumOptions(fieldType) };
      }),
    );
  }
  return result;
}
