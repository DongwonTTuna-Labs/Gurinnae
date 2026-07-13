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
  readonly?: boolean;
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
  const fields: RuntimeField[] = [];
  for (const parameter of indexed.operation.parameters ?? []) {
    if (parameter.in !== "query") continue;
    fields.push(
      runtimeField(
        indexed.document,
        parameter.name,
        parameter.schema,
        parameter.required === true,
        params,
        preset,
      ),
    );
  }
  const schema =
    indexed.operation.requestBody?.content?.["application/json"]?.schema;
  if (schema === undefined) return fields;
  const resolved = resolveSchema(indexed.document, schema);
  const object = chooseObject(indexed.document, resolved);
  const required = new Set(object.required ?? []);
  for (const [name, propertySchema] of Object.entries(
    object.properties ?? {},
  )) {
    if (fields.some((field) => field.name === name)) continue;
    fields.push(
      runtimeField(
        indexed.document,
        name,
        propertySchema,
        required.has(name),
        params,
        preset,
      ),
    );
  }
  return fields;
}

function runtimeField(
  document: OpenApiDocument,
  name: string,
  schema: JsonSchema,
  required: boolean,
  params: RouteParams,
  preset: Record<string, unknown>,
): RuntimeField {
  const field = resolveSchema(document, choose(document, schema));
  const routeValue = params[name] ?? params[camelToRouteParam(name)];
  const presetValue = preset[name] ?? preset[snakeCase(name)];
  const candidate =
    routeValue ?? presetValue ?? defaultValue(name, field, required);
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
  return {
    name,
    label: humanize(name),
    type: inputType(field),
    required,
    ...(options && options.length > 0 ? { options } : {}),
    ...(value !== undefined ? { value } : {}),
    ...(routeValue !== undefined || presetValue !== undefined
      ? { readonly: true }
      : {}),
  };
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
      if (raw === null || String(raw).trim() === "") {
        if (field.required) value[field.name] = false;
        continue;
      }
      if (raw === "true" || raw === "on") value[field.name] = true;
      else if (raw === "false" || raw === "off") value[field.name] = false;
      else throw new Error(`${field.label} 값이 올바르지 않습니다.`);
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

export function optimisticVersion(value: unknown): number | undefined {
  const selectors = [
    (key: string) => key === "expectedVersion",
    (key: string) =>
      key === "currentVersion" || /^current[A-Z].*Version$/.test(key),
    (key: string) => key === "resourceVersion",
    (key: string) => key === "version",
  ];
  for (const selector of selectors) {
    const found = findNumber(value, selector, new WeakSet<object>());
    if (found !== undefined) return found;
  }
  return undefined;
}

function findNumber(
  value: unknown,
  matches: (key: string) => boolean,
  seen: WeakSet<object>,
): number | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  if (seen.has(value)) return undefined;
  seen.add(value);
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findNumber(item, matches, seen);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  for (const [key, item] of Object.entries(value)) {
    if (
      matches(key) &&
      typeof item === "number" &&
      Number.isSafeInteger(item) &&
      item >= 0
    )
      return item;
  }
  for (const item of Object.values(value)) {
    const found = findNumber(item, matches, seen);
    if (found !== undefined) return found;
  }
  return undefined;
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
  required: boolean,
): string | number | boolean | undefined {
  if (name === "expectedVersion") return 1;
  if (!required) return undefined;
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
