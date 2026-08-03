import publicApi from "../../../specs/generated/public-api.openapi.json";

function sortedJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortedJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortedJson(item)]),
  );
}

const canonicalPublicOpenApi = JSON.stringify(sortedJson(publicApi));

// The runtime operation returns the generated document itself, not the shared
// BinaryDownload envelope used by CSV/JSONL export operations.
export function isCanonicalPublicOpenApiDocument(value: unknown): boolean {
  return JSON.stringify(sortedJson(value)) === canonicalPublicOpenApi;
}

export function publicOpenApiMockResponse(): Response {
  return Response.json(publicApi);
}
