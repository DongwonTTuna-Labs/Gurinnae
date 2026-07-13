export type JsonSchema = {
  $ref?: string;
  type?: string | string[];
  format?: string;
  enum?: unknown[];
  anyOf?: JsonSchema[];
  oneOf?: JsonSchema[];
  allOf?: JsonSchema[];
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  minItems?: number;
};

export type OpenApiOperation = {
  operationId: string;
  requestBody?: { content?: { "application/json"?: { schema?: JsonSchema } } };
  parameters?: Array<{
    name: string;
    in: string;
    required?: boolean;
    schema: JsonSchema;
  }>;
  [key: `x-${string}`]: unknown;
};

export type OpenApiDocument = {
  paths: Record<string, Record<string, OpenApiOperation | unknown>>;
  components?: { schemas?: Record<string, JsonSchema> };
};

export type RuntimeField = {
  name: string;
  label: string;
  type: "text" | "number" | "boolean" | "date" | "datetime-local" | "json";
  required: boolean;
  options?: readonly string[];
  value?: string | number | boolean;
};

export type IndexedOperation = {
  operation: OpenApiOperation;
  path: string;
  method: string;
  document: OpenApiDocument;
};

export type RouteParams = Record<string, string | undefined>;

export function indexOperations(
  documents: readonly OpenApiDocument[],
): Map<string, IndexedOperation> {
  const result = new Map<string, IndexedOperation>();
  for (const document of documents) {
    for (const [path, pathItem] of Object.entries(document.paths)) {
      for (const [method, candidate] of Object.entries(pathItem)) {
        if (
          typeof candidate === "object" &&
          candidate !== null &&
          "operationId" in candidate &&
          typeof candidate.operationId === "string"
        ) {
          result.set(candidate.operationId, {
            operation: candidate as OpenApiOperation,
            path,
            method: method.toUpperCase(),
            document,
          });
        }
      }
    }
  }
  return result;
}

export function resolveSchema(
  document: OpenApiDocument,
  schema: JsonSchema,
): JsonSchema {
  if (schema.$ref === undefined) return schema;
  const prefix = "#/components/schemas/";
  if (!schema.$ref.startsWith(prefix))
    throw new Error("unsupported OpenAPI reference");
  const resolved =
    document.components?.schemas?.[schema.$ref.slice(prefix.length)];
  if (resolved === undefined)
    throw new Error("missing OpenAPI schema reference");
  return resolveSchema(document, resolved);
}

export function operationFields(
  indexed: IndexedOperation,
  params: RouteParams,
  preset: Record<string, unknown> = {},
): RuntimeField[] {
  const schema =
    indexed.operation.requestBody?.content?.["application/json"]?.schema;
  if (schema === undefined) return [];
  const resolved = resolveSchema(indexed.document, schema);
  const object = chooseObject(indexed.document, resolved);
  const required = new Set(object.required ?? []);
  return Object.entries(object.properties ?? {}).map(
    ([name, propertySchema]) => {
      const field = resolveSchema(
        indexed.document,
        choose(indexed.document, propertySchema),
      );
      const routeValue = params[name] ?? params[camelToRouteParam(name)];
      const presetValue = preset[name] ?? preset[snakeCase(name)];
      const candidate = routeValue ?? presetValue ?? defaultValue(name, field);
      const value =
        typeof candidate === "string" ||
        typeof candidate === "number" ||
        typeof candidate === "boolean"
          ? candidate
          : candidate !== undefined
            ? JSON.stringify(candidate)
            : undefined;
      const options = field.enum?.filter(
        (item): item is string => typeof item === "string",
      );
      const base = {
        name,
        label: humanize(name),
        type: inputType(field),
        required: required.has(name),
        ...(options && options.length > 0 ? { options } : {}),
        ...(value !== undefined ? { value } : {}),
      };
      return base satisfies RuntimeField;
    },
  );
}

export function formPayload(
  form: FormData,
  fields: readonly RuntimeField[],
  preset: Record<string, unknown> = {},
): Record<string, unknown> {
  const value: Record<string, unknown> = { ...preset };
  for (const field of fields) {
    const raw = form.get(field.name);
    if (field.type === "boolean") {
      value[field.name] = raw === "true" || raw === "on";
    } else if (raw !== null && String(raw).trim() !== "") {
      const text = String(raw);
      if (field.type === "number") value[field.name] = Number(text);
      else if (field.type === "json") value[field.name] = JSON.parse(text);
      else if (field.type === "datetime-local")
        value[field.name] = new Date(text).toISOString();
      else value[field.name] = text;
    } else if (field.required) {
      throw new Error(`${field.label} 값이 필요합니다.`);
    }
  }
  return value;
}

export function bindPath(path: string, params: RouteParams): string {
  return path.replaceAll(/\{([^}]+)\}/g, (_, name: string) => {
    const value = params[name];
    if (value === undefined)
      throw new Error(`route parameter ${name} is missing`);
    return encodeURIComponent(value);
  });
}

function chooseObject(
  document: OpenApiDocument,
  schema: JsonSchema,
): JsonSchema {
  const selected = choose(document, schema);
  const resolved = resolveSchema(document, selected);
  if (resolved.allOf) {
    const properties: Record<string, JsonSchema> = {};
    const required: string[] = [];
    for (const item of resolved.allOf) {
      const part = chooseObject(document, item);
      Object.assign(properties, part.properties ?? {});
      required.push(...(part.required ?? []));
    }
    return { type: "object", properties, required: [...new Set(required)] };
  }
  return resolved;
}

function choose(document: OpenApiDocument, schema: JsonSchema): JsonSchema {
  const resolved = resolveSchema(document, schema);
  const union = resolved.anyOf ?? resolved.oneOf;
  if (!union) return resolved;
  return (
    union
      .map((item) => resolveSchema(document, item))
      .find((item) => item.type !== "null") ??
    union[0] ??
    {}
  );
}

function inputType(schema: JsonSchema): RuntimeField["type"] {
  if (schema.enum) return "text";
  if (schema.format === "date") return "date";
  if (schema.format === "date-time") return "datetime-local";
  if (schema.type === "boolean") return "boolean";
  if (schema.type === "integer" || schema.type === "number") return "number";
  if (
    schema.type === "object" ||
    schema.type === "array" ||
    schema.properties ||
    schema.items
  )
    return "json";
  return "text";
}

function defaultValue(
  name: string,
  schema: JsonSchema,
): string | number | boolean | undefined {
  if (name === "expectedVersion") return 1;
  if (schema.type === "boolean") return false;
  if (schema.type === "object") return "{}";
  if (schema.type === "array") return "[]";
  return undefined;
}

function humanize(name: string): string {
  return name.replaceAll(/([a-z0-9])([A-Z])/g, "$1 $2").replaceAll("_", " ");
}

function snakeCase(name: string): string {
  return name.replaceAll(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}

function camelToRouteParam(name: string): string {
  return name.endsWith("Id") ? `${name.slice(0, -2)}Id` : name;
}
