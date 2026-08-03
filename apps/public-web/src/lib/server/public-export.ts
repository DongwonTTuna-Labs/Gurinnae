import { createHash } from "node:crypto";
import { invokePublicOperation } from "@gurine/api-client-public";
import { requiredServerValue } from "@gurine/config";
import { urlFilterContractFor } from "@gurine/ui";
import * as v from "valibot";
import { env } from "$env/dynamic/private";
import {
  OPERATIONAL_INTERPRETATION_NOTICE,
  PUBLIC_EXPORT_NOTICE,
  type PublicExportFormat,
  type PublicExportKind,
  type VerifiedPublicDownloadPayload,
  verifiedPublicDownloadPayload,
} from "./public-export-artifact";

export type { PublicExportFormat, PublicExportKind };
export {
  OPERATIONAL_INTERPRETATION_NOTICE as PUBLIC_OPERATIONAL_INTERPRETATION_NOTICE,
  PUBLIC_EXPORT_NOTICE,
  verifiedPublicDownloadPayload,
};
export type PublicExportScreenId = "PUB-002" | "PUB-003";

const DATASET_EXPORT_GUIDANCE =
  "현재 조건의 결과가 5,000건을 초과합니다. 전체 자료는 데이터 내려받기에서 요청하세요.";
const text = v.pipe(v.string(), v.minLength(1), v.maxLength(256));
const uuid = v.pipe(v.string(), v.uuid());
const date = v.pipe(v.string(), v.isoDate());
const region2 = v.pipe(v.string(), v.regex(/^[0-9]{2}$/u));
const region5 = v.pipe(v.string(), v.regex(/^[0-9]{5}$/u));
const textList = v.pipe(v.array(text), v.maxLength(32));

const searchFiltersSchema = v.strictObject({
  q: v.pipe(v.string(), v.minLength(2), v.maxLength(500)),
  types: v.optional(textList),
  publicationState: v.optional(textList),
  agencyId: v.optional(uuid),
  sidoCode: v.optional(region2),
  sigunguCode: v.optional(region5),
  dateFrom: v.optional(date),
  dateTo: v.optional(date),
  sort: v.optional(v.picklist(["relevance", "updated_desc", "title_asc"])),
});

const caseFiltersSchema = v.strictObject({
  publicationState: v.optional(textList),
  agencyId: v.optional(uuid),
  supplierId: v.optional(uuid),
  ruleId: v.optional(text),
  sidoCode: v.optional(region2),
  sigunguCode: v.optional(region5),
  publishedFrom: v.optional(date),
  publishedTo: v.optional(date),
  hasResponse: v.optional(v.boolean()),
  hasCorrection: v.optional(v.boolean()),
  sort: v.optional(v.picklist(["updated_desc", "published_desc", "title_asc"])),
});

const problemCodeSchema = v.object({ code: v.string() });

type PublicExportRequest = Readonly<{
  format: PublicExportFormat;
  filters: Readonly<Record<string, string | boolean | readonly string[]>>;
}>;

type PublicExportInputBase = Readonly<{
  fetch: typeof globalThis.fetch;
  url: URL;
}>;

type PublicExportInput = PublicExportInputBase &
  (
    | Readonly<{
        kind: "CASES";
        operationId: "downloadPublicCases";
        screenId: "PUB-003";
      }>
    | Readonly<{
        kind: "SEARCH";
        operationId: "downloadPublicSearchRecords";
        screenId: "PUB-002";
      }>
  );

export type { VerifiedPublicDownloadPayload };

export async function publicExportResponse(
  input: PublicExportInput,
): Promise<Response> {
  const request = parsePublicExportRequest(
    input.screenId,
    input.url.searchParams,
  );
  if (!request)
    return failureResponse(400, "내려받기 조건이 올바르지 않습니다.");

  try {
    const result = await invokePublicOperation({
      operationId: input.operationId,
      baseUrl: requiredServerValue(env, "PUBLIC_API_INTERNAL_URL"),
      fetch: input.fetch,
      query: { ...request.filters, format: request.format },
    });
    if (!result.response?.ok) {
      if (isExportLimitProblem(result.response?.status, result.error)) {
        return datasetGuidanceResponse();
      }
      return failureResponse(
        validFailureStatus(result.response?.status),
        "내려받기를 준비하지 못했습니다.",
      );
    }
    return verifiedDownloadResponse(result.data, request, input.kind);
  } catch {
    return failureResponse(503, "내려받기를 준비하지 못했습니다.");
  }
}

export function publicExportDestination(
  screenId: PublicExportScreenId,
  format: PublicExportFormat,
  current: URLSearchParams,
): string | undefined {
  const route =
    screenId === "PUB-002" ? "/downloads/search" : "/downloads/cases";
  const selected = selectedFilterParams(screenId, current);
  selected.set("format", format);
  const request = parsePublicExportRequest(screenId, selected);
  if (!request) return undefined;
  return `${route}?${serializedExportQuery(request).toString()}`;
}

export function parsePublicExportRequest(
  screenId: PublicExportScreenId,
  current: URLSearchParams,
): PublicExportRequest | undefined {
  const contract = urlFilterContractFor(screenId);
  if (!contract) return undefined;
  const allowed = new Set([...contract.queryKeys, "format"]);
  if ([...current.keys()].some((name) => !allowed.has(name))) return undefined;

  const formats = current.getAll("format");
  if (formats.length !== 1 || !isExportFormat(formats[0])) return undefined;
  const candidate: Record<string, string | boolean | string[]> = {};
  for (const name of contract.queryKeys) {
    const values = current
      .getAll(name)
      .flatMap((value) =>
        contract.arrayKeys.includes(name) ? value.split(",") : [value],
      )
      .map((value) => value.trim())
      .filter(Boolean);
    if (values.length === 0) continue;
    if (contract.arrayKeys.includes(name)) {
      candidate[name] = [...new Set(values)];
      continue;
    }
    if (values.length !== 1) return undefined;
    if (name === "hasResponse" || name === "hasCorrection") {
      if (values[0] !== "true" && values[0] !== "false") return undefined;
      candidate[name] = values[0] === "true";
    } else {
      candidate[name] = values[0] ?? "";
    }
  }
  const parsed = v.safeParse(
    screenId === "PUB-002" ? searchFiltersSchema : caseFiltersSchema,
    candidate,
  );
  if (!parsed.success) return undefined;
  const filters: Record<string, string | boolean | readonly string[]> = {};
  for (const [name, value] of Object.entries(parsed.output)) {
    if (value !== undefined) filters[name] = value;
  }
  if (screenId === "PUB-002") {
    const types = candidate.types;
    filters.types = [
      ...new Set(
        (Array.isArray(types) ? types : []).map((value) => value.toUpperCase()),
      ),
    ];
  }
  filters.publicationState = parsed.output.publicationState ?? [];
  filters.sort ??= screenId === "PUB-002" ? "relevance" : "updated_desc";
  return { format: formats[0], filters };
}

function verifiedDownloadResponse(
  value: unknown,
  request: PublicExportRequest,
  kind: Exclude<PublicExportKind, "CONTRACTS">,
): Response {
  const payload = verifiedPublicDownloadPayload(value, {
    format: request.format,
    kind,
    expectedFilters: request.filters,
  });
  if (!payload)
    return failureResponse(502, "내려받기 응답 계약이 일치하지 않습니다.");
  // Make the owned ArrayBuffer boundary explicit for DOM's BodyInit type.
  const responseBytes = Uint8Array.from(payload.bytes);
  return new Response(responseBytes, {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-disposition": contentDisposition(payload.filename),
      "content-length": String(payload.bytes.byteLength),
      "content-type": payload.mediaType,
      "x-content-sha256": createHash("sha256")
        .update(payload.bytes)
        .digest("hex"),
      "x-content-type-options": "nosniff",
    },
  });
}

function selectedFilterParams(
  screenId: PublicExportScreenId,
  current: URLSearchParams,
): URLSearchParams {
  const selected = new URLSearchParams();
  const contract = urlFilterContractFor(screenId);
  if (!contract) return selected;
  for (const name of contract.queryKeys) {
    for (const value of current.getAll(name)) {
      if (value.trim()) selected.append(name, value);
    }
  }
  return selected;
}

function serializedExportQuery(request: PublicExportRequest): URLSearchParams {
  const query = new URLSearchParams();
  for (const [name, value] of Object.entries(request.filters)) {
    if (Array.isArray(value)) {
      for (const item of value) query.append(name, item);
    } else {
      query.set(name, String(value));
    }
  }
  query.set("format", request.format);
  return query;
}

function isExportLimitProblem(
  status: number | undefined,
  value: unknown,
): boolean {
  const problem = v.safeParse(problemCodeSchema, value);
  return (
    status === 422 &&
    problem.success &&
    problem.output.code === "PRECONDITION_FAILED"
  );
}

function datasetGuidanceResponse(): Response {
  const query = new URLSearchParams({ notice: DATASET_EXPORT_GUIDANCE });
  return new Response(null, {
    status: 303,
    headers: {
      "cache-control": "no-store",
      location: `/data?${query.toString()}`,
      "x-content-type-options": "nosniff",
    },
  });
}

function failureResponse(status: number, message: string): Response {
  return new Response(message, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "text/plain; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

function validFailureStatus(status: number | undefined): number {
  return status && status >= 400 && status <= 599 ? status : 503;
}

function contentDisposition(filename: string): string {
  const fallback = filename.replaceAll(/[^A-Za-z0-9._-]/g, "_");
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function isExportFormat(
  value: string | undefined,
): value is PublicExportFormat {
  return value === "CSV" || value === "JSONL";
}
