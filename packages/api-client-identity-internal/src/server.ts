import { createClient } from "./generated/client";
import * as operations from "./generated/sdk.gen";

export type IdentityOperationInput = {
  operationId: string;
  baseUrl: string;
  fetch: typeof globalThis.fetch;
  body?: unknown;
  headers?: Record<string, string>;
};

export type IdentityOperationResult = {
  data: unknown;
  error: unknown;
  request?: Request;
  response?: Response;
};

export async function invokeIdentityOperation(
  input: IdentityOperationInput,
): Promise<IdentityOperationResult> {
  const operation = (operations as Record<string, unknown>)[input.operationId];
  if (typeof operation !== "function") {
    throw new Error(
      `generated identity operation ${input.operationId} is missing`,
    );
  }
  const client = createClient({
    baseUrl: input.baseUrl,
    fetch: input.fetch,
    responseStyle: "fields",
  });
  const value: unknown = await (
    operation as (options: unknown) => Promise<unknown>
  )({
    client,
    ...(input.body !== undefined ? { body: input.body } : {}),
    ...(input.headers ? { headers: input.headers } : {}),
  });
  return operationResult(value, input.operationId);
}

function operationResult(
  value: unknown,
  operationId: string,
): IdentityOperationResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(
      `generated identity operation ${operationId} returned an invalid result`,
    );
  }
  const result = value as Record<string, unknown>;
  return {
    data: result.data,
    error: result.error,
    ...(result.request instanceof Request ? { request: result.request } : {}),
    ...(result.response instanceof Response
      ? { response: result.response }
      : {}),
  };
}
