import { createClient } from "./generated/client";
import * as operations from "./generated/sdk.gen";

export type PublicOperationResult = {
  data: unknown;
  error: unknown;
  request?: Request;
  response?: Response;
};

export async function invokePublicOperation(input: {
  operationId: string;
  baseUrl: string;
  fetch: typeof globalThis.fetch;
  path?: Record<string, unknown>;
  query?: Record<string, unknown>;
}): Promise<PublicOperationResult> {
  const client = createClient({
    baseUrl: input.baseUrl,
    fetch: input.fetch,
    responseStyle: "fields",
  });
  const operation = (operations as Record<string, unknown>)[input.operationId];
  if (typeof operation !== "function") {
    throw new Error(
      `generated public operation ${input.operationId} is missing`,
    );
  }
  const result: unknown = await (
    operation as (options: unknown) => Promise<unknown>
  )({
    client,
    ...(input.path ? { path: input.path } : {}),
    ...(input.query ? { query: input.query } : {}),
  });
  return operationResult(result, input.operationId);
}

function operationResult(
  value: unknown,
  operationId: string,
): PublicOperationResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(
      `generated public operation ${operationId} returned an invalid result`,
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
