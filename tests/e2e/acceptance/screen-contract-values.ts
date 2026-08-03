export type ObjectValue = Record<string, unknown>;

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

export function integerValue(value: unknown, context: string): number {
  if (typeof value !== "number" || !Number.isInteger(value))
    throw new Error(`${context} must be an integer`);
  return value;
}
