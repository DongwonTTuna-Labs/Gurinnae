import { readFileSync } from "node:fs";
import { parse } from "yaml";
import operationSamples from "../../../verification/generated-operation-samples.json";

type ObjectValue = Record<string, unknown>;
type LabelContract = Readonly<{
  operationIds: readonly string[];
  labelOperationIds: readonly string[];
  screenBindings: readonly string[];
  runtimeOnlyOperationIds: readonly string[];
  fields: ReadonlySet<string>;
  enums: ReadonlySet<string>;
  runtimeOnlyFields: ReadonlySet<string>;
  runtimeOnlyEnums: ReadonlySet<string>;
  transportOnlyFields: ReadonlySet<string>;
}>;
type LabelCollector = {
  fields: Set<string>;
  enums: Set<string>;
};

export const R6E_OPERATION_IDS: readonly string[] = Object.freeze([
  "downloadTransparencyReport",
  "getFundingContent",
  "listTransparencyReports",
  "private.GetDonationFixtureOffer",
  "private.QueueDonationIntent",
  "private.ReceivePaymentWebhook",
]);

export const R6E_SCREEN_BINDINGS: readonly string[] = Object.freeze([
  "PUB-023:downloadTransparencyReport",
  "PUB-023:getFundingContent",
  "PUB-023:listTransparencyReports",
  "PUB-035:private.GetDonationFixtureOffer",
  "PUB-035:private.QueueDonationIntent",
]);

export const R6E_SCREEN_OPERATION_IDS: readonly string[] = Object.freeze([
  "downloadTransparencyReport",
  "getFundingContent",
  "listTransparencyReports",
  "private.GetDonationFixtureOffer",
  "private.QueueDonationIntent",
]);

export const R6E_RUNTIME_ONLY_OPERATION_IDS: readonly string[] = Object.freeze([
  "private.ReceivePaymentWebhook",
]);

export const R6E_RUNTIME_ONLY_FIELD_LABEL_GAPS: readonly string[] =
  Object.freeze([
    "contentType",
    "disposition",
    "eventIdentitySha256",
    "rawBody",
    "stripeSignature",
  ]);

export const R6E_RUNTIME_ONLY_ENUM_LABEL_GAPS: readonly string[] =
  Object.freeze(["APPLIED"]);

export const R6E_TRANSPORT_ONLY_FIELD_LABEL_GAPS: readonly string[] =
  Object.freeze(["X-Request-ID"]);

/**
 * Provenance: the generated operation-sample and mock-response collectors expose
 * these exact historical base/R6d/provider gaps. A transitive operation-to-screen
 * audit found no intersection with PUB-023, PUB-035, or the six R6e operations.
 * These frozen test-only sets are exact drift sensors, never runtime allowlists;
 * `fieldLabel` and `presentEnumValue` remain fail-closed for every missing value.
 */
export const PRE_R6E_ENUM_LABEL_GAPS: readonly string[] = Object.freeze([
  "DELIVERY",
  "NATURAL_PERSON",
  "PROVIDER_ACKNOWLEDGEMENT",
]);

export const PRE_R6E_FIELD_LABEL_GAPS: readonly string[] = Object.freeze([
  "accessProjection",
  "assertionId",
  "authorityReceiptDigest",
  "authorityReceiptId",
  "closureAt",
  "closureReceiptId",
  "completedResponseVersion",
  "completedValueDigest",
  "completionReceiptDigest",
  "correctionPlanId",
  "currentValueDigest",
  "deliveryVersion",
  "entityId",
  "entityKind",
  "evidenceKind",
  "evidenceSegmentId",
  "fieldPath",
  "gateState",
  "lastContractEndAt",
  "linkedPublicationRevisionCount",
  "locatorSha256",
  "nonConclusionNotices",
  "personhoodReceiptId",
  "planVersion",
  "privacyIdentityProofReceiptDigest",
  "privacyIdentityProofReceiptId",
  "providerEventIdentityHmac",
  "registryReceiptDigest",
  "responseOriginReceiptDigest",
  "responseOriginReceiptId",
  "responseSubmissionReceiptDigest",
  "responseSubmissionReceiptId",
  "responseVersion",
  "revocationId",
  "selectedContentSha256",
  "sourceResponseRequestId",
  "targetObjectId",
  "targetObjectType",
]);

function isObjectValue(value: unknown): value is ObjectValue {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function objectValue(value: unknown, context: string): ObjectValue {
  if (!isObjectValue(value)) throw new Error(`${context} must be an object`);
  return value;
}

function yamlObject(relativePath: string): ObjectValue {
  const value: unknown = parse(
    readFileSync(new URL(`../../../${relativePath}`, import.meta.url), "utf8"),
  );
  return objectValue(value, relativePath);
}

function jsonObject(relativePath: string): ObjectValue {
  const value: unknown = JSON.parse(
    readFileSync(new URL(`../../../${relativePath}`, import.meta.url), "utf8"),
  );
  return objectValue(value, relativePath);
}

function sorted(values: Iterable<string>): string[] {
  return [...new Set(values)].sort();
}

function isEnumLiteral(value: string): boolean {
  return /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$/u.test(value);
}

function collectEnumLiteral(value: unknown, result: Set<string>): void {
  if (typeof value === "string" && isEnumLiteral(value)) result.add(value);
}

export function collectNestedFieldNames(
  value: unknown,
  result: Set<string>,
): void {
  if (Array.isArray(value)) {
    for (const item of value) collectNestedFieldNames(item, result);
    return;
  }
  if (!isObjectValue(value)) return;
  for (const [key, child] of Object.entries(value)) {
    result.add(key);
    collectNestedFieldNames(child, result);
  }
}

export function operationSampleFields(): Set<string> {
  const result = new Set<string>();
  for (const sample of Object.values(operationSamples)) {
    if (isObjectValue(sample) && "body" in sample)
      collectNestedFieldNames(sample.body, result);
  }
  return result;
}

function resolveLocalReference(
  document: ObjectValue,
  reference: string,
): unknown {
  if (!reference.startsWith("#/"))
    throw new Error(`unsupported OpenAPI reference: ${reference}`);
  let value: unknown = document;
  for (const rawSegment of reference.slice(2).split("/")) {
    const segment = rawSegment.replaceAll("~1", "/").replaceAll("~0", "~");
    value = objectValue(value, reference)[segment];
  }
  if (value === undefined)
    throw new Error(`missing OpenAPI reference: ${reference}`);
  return value;
}

function collectOpenApiSchema(
  value: unknown,
  document: ObjectValue,
  collector: LabelCollector,
  seenReferences: ReadonlySet<string>,
): void {
  if (!isObjectValue(value)) return;
  if (typeof value.$ref === "string") {
    if (seenReferences.has(value.$ref)) return;
    collectOpenApiSchema(
      resolveLocalReference(document, value.$ref),
      document,
      collector,
      new Set([...seenReferences, value.$ref]),
    );
  }
  if (isObjectValue(value.properties)) {
    for (const [name, schema] of Object.entries(value.properties)) {
      collector.fields.add(name);
      collectOpenApiSchema(schema, document, collector, seenReferences);
    }
  }
  if (Array.isArray(value.enum))
    for (const item of value.enum) collectEnumLiteral(item, collector.enums);
  collectEnumLiteral(value.const, collector.enums);
  collectOpenApiSchema(value.items, document, collector, seenReferences);
  for (const union of [value.anyOf, value.oneOf, value.allOf])
    if (Array.isArray(union))
      for (const schema of union)
        collectOpenApiSchema(schema, document, collector, seenReferences);
}

function collectSchemasInContainer(
  value: unknown,
  document: ObjectValue,
  collector: LabelCollector,
  seenReferences: ReadonlySet<string> = new Set(),
): void {
  if (Array.isArray(value)) {
    for (const item of value)
      collectSchemasInContainer(item, document, collector, seenReferences);
    return;
  }
  if (!isObjectValue(value)) return;
  if (typeof value.$ref === "string") {
    if (seenReferences.has(value.$ref)) return;
    collectSchemasInContainer(
      resolveLocalReference(document, value.$ref),
      document,
      collector,
      new Set([...seenReferences, value.$ref]),
    );
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === "schema")
      collectOpenApiSchema(child, document, collector, new Set());
    else if (key !== "$ref")
      collectSchemasInContainer(child, document, collector, seenReferences);
  }
}

function collectParameter(
  value: unknown,
  document: ObjectValue,
  collector: LabelCollector,
  transportCollector: LabelCollector,
): void {
  const parameter =
    isObjectValue(value) && typeof value.$ref === "string"
      ? objectValue(resolveLocalReference(document, value.$ref), value.$ref)
      : objectValue(value, "OpenAPI parameter");
  if (parameter.in === "header") {
    if (typeof parameter.name === "string")
      transportCollector.fields.add(parameter.name);
    collectOpenApiSchema(
      parameter.schema,
      document,
      transportCollector,
      new Set(),
    );
    return;
  }
  if (parameter.in !== "query" && parameter.in !== "path") return;
  if (typeof parameter.name === "string") collector.fields.add(parameter.name);
  collectOpenApiSchema(parameter.schema, document, collector, new Set());
}

function collectPublicOperations(
  collector: LabelCollector,
  transportCollector: LabelCollector,
): string[] {
  const document = jsonObject("specs/generated/public-api.openapi.json");
  const paths = objectValue(document.paths, "public-api paths");
  const target = new Set(
    R6E_OPERATION_IDS.filter((id) => !id.startsWith("private.")),
  );
  const found = new Set<string>();
  for (const pathItemValue of Object.values(paths)) {
    const pathItem = objectValue(pathItemValue, "public-api path item");
    for (const [method, operationValue] of Object.entries(pathItem)) {
      if (!new Set(["get", "post", "put", "patch", "delete"]).has(method))
        continue;
      const operation = objectValue(operationValue, `public-api ${method}`);
      if (
        typeof operation.operationId !== "string" ||
        !target.has(operation.operationId)
      )
        continue;
      found.add(operation.operationId);
      for (const parameter of [
        ...(Array.isArray(pathItem.parameters) ? pathItem.parameters : []),
        ...(Array.isArray(operation.parameters) ? operation.parameters : []),
      ])
        collectParameter(parameter, document, collector, transportCollector);
      collectSchemasInContainer(operation.requestBody, document, collector);
      if (isObjectValue(operation.responses))
        for (const [status, response] of Object.entries(operation.responses))
          if (/^2\d\d$/u.test(status))
            collectSchemasInContainer(response, document, collector);
    }
  }
  return sorted(found);
}

function collectTypeExpression(
  value: unknown,
  schemas: ObjectValue,
  collector: LabelCollector,
  seenSchemas: Set<string>,
): void {
  if (typeof value !== "string") return;
  for (const match of value.matchAll(/(?:enum|const)<([^<>]+)>/gu))
    for (const option of (match[1] ?? "").split("|"))
      collectEnumLiteral(option, collector.enums);
  for (const match of value.matchAll(/\b[A-Z][A-Za-z0-9]*V\d+\b/gu)) {
    const name = match[0];
    if (schemas[name] === undefined || seenSchemas.has(name)) continue;
    seenSchemas.add(name);
    collectPrivateSchema(schemas[name], schemas, collector, seenSchemas);
  }
}

function collectPrivateSchema(
  value: unknown,
  schemas: ObjectValue,
  collector: LabelCollector,
  seenSchemas: Set<string>,
): void {
  if (!isObjectValue(value)) {
    collectTypeExpression(value, schemas, collector, seenSchemas);
    return;
  }
  if (isObjectValue(value.fields)) {
    for (const [name, fieldType] of Object.entries(value.fields)) {
      collector.fields.add(name);
      collectTypeExpression(fieldType, schemas, collector, seenSchemas);
    }
  }
  if (isObjectValue(value.variants))
    for (const variant of Object.values(value.variants))
      collectPrivateSchema(variant, schemas, collector, seenSchemas);
}

function collectPrivateOperations(
  collector: LabelCollector,
  runtimeOnlyCollector: LabelCollector,
): string[] {
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
  const requests = objectValue(
    resources.private_billing_gateway_request_schemas,
    "private billing request schemas",
  );
  const schemas = objectValue(resources.schemas, "addendum schemas");
  const expected = R6E_OPERATION_IDS.filter((id) => id.startsWith("private."));
  if (
    JSON.stringify(sorted(Object.keys(operations))) !== JSON.stringify(expected)
  )
    throw new Error("private billing operation set differs from exact R6e set");
  for (const operationId of expected) {
    const operation = objectValue(operations[operationId], operationId);
    const binding = objectValue(
      bindings[operationId],
      `${operationId} binding`,
    );
    if (
      binding.request_schema !== operation.request_schema ||
      binding.success_schema !== operation.response_schema
    )
      throw new Error(`${operationId} private billing schema binding mismatch`);
    const operationCollector = R6E_RUNTIME_ONLY_OPERATION_IDS.includes(
      operationId,
    )
      ? runtimeOnlyCollector
      : collector;
    collectPrivateSchema(
      requests[operationId],
      schemas,
      operationCollector,
      new Set(),
    );
    const responseSchema = String(operation.response_schema);
    collectPrivateSchema(
      schemas[responseSchema],
      schemas,
      operationCollector,
      new Set([responseSchema]),
    );
  }
  return expected;
}

function r6eScreenBindings(): string[] {
  const catalog = yamlObject("specs/ui/screen-catalog.yaml");
  const target = new Set(R6E_OPERATION_IDS);
  const bindings = new Set<string>();
  if (!Array.isArray(catalog.screens))
    throw new Error("screen catalog is invalid");
  for (const value of catalog.screens) {
    const screen = objectValue(value, "screen catalog row");
    const screenId = String(screen.id);
    for (const key of ["actions", "data_requirements"]) {
      if (!Array.isArray(screen[key])) continue;
      for (const rowValue of screen[key]) {
        const row = objectValue(rowValue, `${screenId}.${key}`);
        if (
          typeof row.operation_id === "string" &&
          target.has(row.operation_id)
        )
          bindings.add(`${screenId}:${row.operation_id}`);
      }
    }
  }
  return sorted(bindings);
}

export function r6eOperationLabelContract(): LabelContract {
  const collector: LabelCollector = { fields: new Set(), enums: new Set() };
  const runtimeOnlyCollector: LabelCollector = {
    fields: new Set(),
    enums: new Set(),
  };
  const transportCollector: LabelCollector = {
    fields: new Set(),
    enums: new Set(),
  };
  const operationIds = sorted([
    ...collectPublicOperations(collector, transportCollector),
    ...collectPrivateOperations(collector, runtimeOnlyCollector),
  ]);
  const screenBindings = r6eScreenBindings();
  const screenOperationIds = new Set(
    screenBindings.map((binding) => binding.slice(binding.indexOf(":") + 1)),
  );
  return {
    operationIds,
    labelOperationIds: sorted(screenOperationIds),
    screenBindings,
    runtimeOnlyOperationIds: operationIds.filter(
      (operationId) => !screenOperationIds.has(operationId),
    ),
    fields: collector.fields,
    enums: collector.enums,
    runtimeOnlyFields: runtimeOnlyCollector.fields,
    runtimeOnlyEnums: runtimeOnlyCollector.enums,
    transportOnlyFields: transportCollector.fields,
  };
}
