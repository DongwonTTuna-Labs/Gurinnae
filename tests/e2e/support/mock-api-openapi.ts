import Ajv2020, {
  type ErrorObject,
  type ValidateFunction,
} from "ajv/dist/2020";
import addFormats from "ajv-formats";
import controlApi from "../../../specs/generated/control-api.openapi.json";
import identityServiceInternal from "../../../specs/generated/identity-service-internal.openapi.json";
import publicApi from "../../../specs/generated/public-api.openapi.json";
import submissionApi from "../../../specs/generated/submission-api.openapi.json";
import { isCanonicalPublicOpenApiDocument } from "./mock-api-openapi-document";

const HTTP_METHODS = new Set(["delete", "get", "patch", "post", "put"]);
const JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema";
const COMPONENT_REF_PREFIX = "#/components/schemas/";

type JsonObject = Record<string, unknown>;
type ContractSource = {
  name: string;
  schemaId: string;
  document: unknown;
};
type ResponseContract = {
  cacheKey: string;
  contents: ReadonlyMap<string, unknown>;
  schemaId: string;
};
type OperationContract = {
  method: string;
  operationId: string;
  pathPattern: RegExp;
  pathSpecificity: number;
  pathTemplate: string;
  responses: ReadonlyMap<number, ResponseContract>;
};
type ResolvedContractMatch = {
  operation: OperationContract;
  response: ResponseContract;
};
type ContractLookup =
  | { ok: true; match: ResolvedContractMatch }
  | { ok: false; operationId: string; violation: Violation };
type Violation = {
  instancePath: string;
  schemaPath: string;
  message: string;
};
type PayloadResult =
  | { ok: true; noContent: true }
  | {
      ok: true;
      cacheKey: string;
      noContent: false;
      schema: unknown;
      value: unknown;
    }
  | { ok: false; violation: Violation };

const CONTRACT_SOURCES: readonly ContractSource[] = [
  {
    name: "control-api",
    schemaId: "urn:gurine:mock-openapi:control-api",
    document: controlApi,
  },
  {
    name: "public-api",
    schemaId: "urn:gurine:mock-openapi:public-api",
    document: publicApi,
  },
  {
    name: "submission-api",
    schemaId: "urn:gurine:mock-openapi:submission-api",
    document: submissionApi,
  },
  {
    name: "identity-service-internal",
    schemaId: "urn:gurine:mock-openapi:identity-service-internal",
    document: identityServiceInternal,
  },
];

/**
 * These are the only responses that intentionally do not belong to an API
 * operation. The upload target is object-storage transport issued by the
 * submission API. identity-api is an unused procurement surface and
 * identity-provider describes the BFF contract, so neither is a mock upstream.
 */
export const MOCK_OPENAPI_BYPASS_ALLOWLIST = Object.freeze([
  { method: "GET", pathTemplate: "/health/ready" },
  { method: "GET", pathTemplate: "/_test/state" },
  { method: "POST", pathTemplate: "/_test/reset" },
  { method: "POST", pathTemplate: "/_test/clear-observations" },
  { method: "PUT", pathTemplate: "/internal/submission-uploads/{uuid}" },
]);

const ajv = new Ajv2020({
  allErrors: true,
  coerceTypes: false,
  removeAdditional: false,
  strict: true,
  useDefaults: false,
  validateFormats: true,
});
addFormats(ajv, { mode: "full" });

function jsonObject(value: unknown): JsonObject | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    return undefined;
  const result: JsonObject = {};
  for (const [key, item] of Object.entries(value)) result[key] = item;
  return result;
}

function requiredObject(parent: JsonObject, key: string, context: string) {
  const value = jsonObject(parent[key]);
  if (!value) throw new Error(`${context}.${key} must be an object`);
  return value;
}

function escapeRegex(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function pathPattern(pathTemplate: string) {
  const parts: string[] = ["^"];
  let cursor = 0;
  for (const match of pathTemplate.matchAll(/\{[^/{}]+\}/g)) {
    const index = match.index;
    parts.push(escapeRegex(pathTemplate.slice(cursor, index)), "[^/]+");
    cursor = index + match[0].length;
  }
  parts.push(escapeRegex(pathTemplate.slice(cursor)), "$");
  return new RegExp(parts.join(""));
}

function absoluteComponentRefs(value: unknown, schemaId: string): unknown {
  if (Array.isArray(value))
    return value.map((item) => absoluteComponentRefs(item, schemaId));
  const object = jsonObject(value);
  if (!object) return value;
  const transformed: JsonObject = {};
  for (const [key, item] of Object.entries(object)) {
    if (key.startsWith("x-")) continue;
    if (key === "$ref" && typeof item === "string") {
      if (!item.startsWith(COMPONENT_REF_PREFIX))
        throw new Error(`unsupported OpenAPI schema reference: ${item}`);
      transformed[key] =
        `${schemaId}#/$defs/${item.slice(COMPONENT_REF_PREFIX.length)}`;
    } else {
      transformed[key] = absoluteComponentRefs(item, schemaId);
    }
  }
  return transformed;
}

function responseContracts(
  source: ContractSource,
  operation: JsonObject,
  operationId: string,
) {
  const responses = requiredObject(operation, "responses", operationId);
  const contracts = new Map<number, ResponseContract>();
  for (const [statusText, value] of Object.entries(responses)) {
    const status = Number(statusText);
    if (!Number.isInteger(status) || status < 100 || status > 599)
      throw new Error(`${operationId} has unsupported response ${statusText}`);
    const response = jsonObject(value);
    if (!response) throw new Error(`${operationId}.${statusText} is invalid`);
    const content =
      response.content === undefined ? {} : jsonObject(response.content);
    if (!content)
      throw new Error(`${operationId}.${statusText}.content is invalid`);
    contracts.set(status, {
      cacheKey: `${source.name}:${operationId}:${statusText}`,
      contents: new Map(Object.entries(content)),
      schemaId: source.schemaId,
    });
  }
  return contracts;
}

function indexSource(source: ContractSource) {
  const document = jsonObject(source.document);
  if (!document) throw new Error(`${source.name} OpenAPI document is invalid`);
  const paths = requiredObject(document, "paths", source.name);
  const operations: OperationContract[] = [];
  for (const [template, rawPath] of Object.entries(paths)) {
    const path = jsonObject(rawPath);
    if (!path) throw new Error(`${source.name} path ${template} is invalid`);
    for (const [method, rawOperation] of Object.entries(path)) {
      if (!HTTP_METHODS.has(method)) continue;
      const operation = jsonObject(rawOperation);
      const operationId = operation?.operationId;
      if (!operation || typeof operationId !== "string")
        throw new Error(
          `${source.name} ${method} ${template} lacks operationId`,
        );
      operations.push({
        method: method.toUpperCase(),
        operationId,
        pathPattern: pathPattern(template),
        pathSpecificity: template.replace(/\{[^/{}]+\}/g, "").length,
        pathTemplate: template,
        responses: responseContracts(source, operation, operationId),
      });
    }
  }
  const components = requiredObject(document, "components", source.name);
  const schemas = requiredObject(
    components,
    "schemas",
    `${source.name}.components`,
  );
  ajv.addSchema({
    $defs: absoluteComponentRefs(schemas, source.schemaId),
    $id: source.schemaId,
    $schema: JSON_SCHEMA_DIALECT,
  });
  return operations;
}

const operations = CONTRACT_SOURCES.flatMap(indexSource);
const validatorCache = new Map<string, ValidateFunction<unknown>>();
const bypassPatterns = MOCK_OPENAPI_BYPASS_ALLOWLIST.map((item) => ({
  ...item,
  pattern:
    item.pathTemplate === "/internal/submission-uploads/{uuid}"
      ? /^\/internal\/submission-uploads\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      : pathPattern(item.pathTemplate),
}));

function isBypassed(request: Request, url: URL) {
  return bypassPatterns.some(
    (item) => item.method === request.method && item.pattern.test(url.pathname),
  );
}

export function mockOperationId(request: Request): string | undefined {
  const url = new URL(request.url);
  const pathMatches = operations.filter(
    (operation) =>
      operation.method === request.method &&
      operation.pathPattern.test(url.pathname),
  );
  const greatestSpecificity = Math.max(
    ...pathMatches.map(({ pathSpecificity }) => pathSpecificity),
  );
  const exactMatches = pathMatches.filter(
    ({ pathSpecificity }) => pathSpecificity === greatestSpecificity,
  );
  return exactMatches.length === 1 ? exactMatches[0]?.operationId : undefined;
}

function findContract(
  request: Request,
  url: URL,
  status: number,
): ContractLookup {
  const rawPathMatches = operations.filter(
    (operation) =>
      operation.method === request.method &&
      operation.pathPattern.test(url.pathname),
  );
  const greatestSpecificity = Math.max(
    ...rawPathMatches.map(({ pathSpecificity }) => pathSpecificity),
  );
  const pathMatches = rawPathMatches.filter(
    ({ pathSpecificity }) => pathSpecificity === greatestSpecificity,
  );
  const statusMatches = pathMatches.flatMap((operation) => {
    const response = operation.responses.get(status);
    return response ? [{ operation, response }] : [];
  });
  const match = statusMatches[0];
  if (statusMatches.length === 1 && match) return { ok: true, match };
  const solePathMatch = pathMatches[0];
  if (pathMatches.length === 1 && solePathMatch) {
    return {
      ok: false,
      operationId: solePathMatch.operationId,
      violation: {
        instancePath: "",
        schemaPath: `#/paths/${solePathMatch.pathTemplate}/${solePathMatch.method.toLowerCase()}/responses`,
        message: `status ${status} is not declared for ${solePathMatch.operationId}`,
      },
    };
  }
  return {
    ok: false,
    operationId:
      statusMatches.length > 1
        ? `AMBIGUOUS(${statusMatches.map(({ operation }) => operation.operationId).join(",")})`
        : "UNMATCHED",
    violation: {
      instancePath: "",
      schemaPath: "#/paths",
      message: `expected exactly one ${request.method} ${url.pathname} status ${status} operation, found ${statusMatches.length}`,
    },
  };
}

function violation(
  schemaPath: string,
  message: string,
  instancePath = "",
): PayloadResult {
  return { ok: false, violation: { instancePath, schemaPath, message } };
}

async function responsePayload(
  response: Response,
  contract: ResponseContract,
): Promise<PayloadResult> {
  let text: string;
  try {
    text = await response.clone().text();
  } catch (error) {
    return violation(
      "#/response/body",
      `response body could not be read: ${String(error)}`,
    );
  }
  if (contract.contents.size === 0) {
    return text.length === 0
      ? { ok: true, noContent: true }
      : violation(
          "#/response/content",
          "body returned for a response with no content",
        );
  }
  if (text.length === 0)
    return violation("#/response/content", "declared response body is empty");
  const contentType = response.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase();
  if (!contentType)
    return violation(
      "#/response/content",
      "response has no content-type header",
    );
  const media = contract.contents.get(contentType);
  const mediaObject = jsonObject(media);
  if (!mediaObject)
    return violation(
      "#/response/content",
      `content-type ${contentType} is not declared`,
    );
  if (!contentType.endsWith("/json") && !contentType.endsWith("+json"))
    return violation(
      "#/response/content",
      `unsupported mock content-type ${contentType}`,
    );
  try {
    return {
      ok: true,
      cacheKey: `${contract.cacheKey}:${contentType}`,
      noContent: false,
      schema: mediaObject.schema,
      value: JSON.parse(text),
    };
  } catch (error) {
    return violation(
      "#/response/body",
      `response is not valid JSON: ${String(error)}`,
    );
  }
}

function validatorFor(
  contract: ResponseContract,
  cacheKey: string,
  schema: unknown,
) {
  const cached = validatorCache.get(cacheKey);
  if (cached) return cached;
  const schemaObject = jsonObject(schema);
  if (!schemaObject) return undefined;
  const absoluteSchema = jsonObject(
    absoluteComponentRefs(schemaObject, contract.schemaId),
  );
  if (!absoluteSchema) return undefined;
  const validator = ajv.compile({
    ...absoluteSchema,
    $schema: JSON_SCHEMA_DIALECT,
  });
  validatorCache.set(cacheKey, validator);
  return validator;
}

function ajvViolations(errors: ErrorObject[] | null | undefined): Violation[] {
  if (!errors?.length)
    return [
      {
        instancePath: "",
        schemaPath: "#/response",
        message: "schema validation failed",
      },
    ];
  return errors.map((error) => ({
    instancePath: error.instancePath,
    schemaPath: error.schemaPath,
    message: error.message ?? "schema validation failed",
  }));
}

function failureResponse(
  request: Request,
  response: Response,
  operationId: string,
  violations: readonly Violation[],
) {
  const payload = {
    error: "MOCK_OPENAPI_RESPONSE_INVALID",
    method: request.method,
    operationId,
    path: new URL(request.url).pathname,
    status: response.status,
    violations,
  };
  console.error(JSON.stringify(payload));
  return Response.json(payload, { status: 500 });
}

export async function validateMockResponse(
  request: Request,
  response: Response,
): Promise<Response> {
  const url = new URL(request.url);
  if (isBypassed(request, url)) return response;
  const lookup = findContract(request, url, response.status);
  if (!lookup.ok)
    return failureResponse(request, response, lookup.operationId, [
      lookup.violation,
    ]);
  const { operation, response: responseContract } = lookup.match;
  const payload = await responsePayload(response, responseContract);
  if (!payload.ok)
    return failureResponse(request, response, operation.operationId, [
      payload.violation,
    ]);
  if (payload.noContent) return response;
  if (operation.operationId === "downloadPublicOpenApi") {
    if (isCanonicalPublicOpenApiDocument(payload.value)) return response;
    return failureResponse(request, response, operation.operationId, [
      {
        instancePath: "",
        schemaPath: "#/paths/~1v1~1openapi.json/get/responses/200",
        message: "payload must equal the generated public OpenAPI document",
      },
    ]);
  }
  let validator: ValidateFunction<unknown> | undefined;
  try {
    validator = validatorFor(
      responseContract,
      payload.cacheKey,
      payload.schema,
    );
  } catch (error) {
    return failureResponse(request, response, operation.operationId, [
      {
        instancePath: "",
        schemaPath: "#/response/schema",
        message: `response schema could not be compiled: ${String(error)}`,
      },
    ]);
  }
  if (!validator)
    return failureResponse(request, response, operation.operationId, [
      {
        instancePath: "",
        schemaPath: "#/response/schema",
        message: "response schema is missing",
      },
    ]);
  if (validator(payload.value)) return response;
  return failureResponse(
    request,
    response,
    operation.operationId,
    ajvViolations(validator.errors),
  );
}
