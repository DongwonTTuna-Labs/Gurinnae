import {
  createClient,
  downloadTransparencyReport,
} from "@gurine/api-client-public";
import { requiredServerValue } from "@gurine/config";
import { env } from "$env/dynamic/private";
import {
  type TransparencyReportFormat,
  verifyTransparencyReportDownload,
} from "./transparency-report-download";

const LOWERCASE_UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

type TransparencyReportRequest = Readonly<{
  reportId: string;
  format: TransparencyReportFormat;
}>;

export async function transparencyReportResponse(input: {
  fetch: typeof globalThis.fetch;
  reportId: string;
  url: URL;
}): Promise<Response> {
  const request = parseTransparencyReportRequest(input.reportId, input.url);
  if (!request) return failureResponse(400);

  try {
    const client = createClient({
      baseUrl: requiredServerValue(env, "PUBLIC_API_INTERNAL_URL"),
      fetch: input.fetch,
      responseStyle: "fields",
    });
    const result = await downloadTransparencyReport({
      client,
      path: { reportId: request.reportId },
      query: { format: request.format },
    });
    if (!result.response?.ok) {
      return failureResponse(upstreamFailureStatus(result.response?.status));
    }

    const download = verifyTransparencyReportDownload(result.data, request);
    if (!download) return failureResponse(502);
    const bytes = Uint8Array.from(download.bytes);
    return new Response(bytes, {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-disposition": contentDisposition(download.filename),
        "content-length": String(bytes.byteLength),
        "content-type": download.mediaType,
        "x-content-sha256": download.contentSha256,
        "x-content-type-options": "nosniff",
      },
    });
  } catch {
    return failureResponse(503);
  }
}

function parseTransparencyReportRequest(
  reportId: string,
  url: URL,
): TransparencyReportRequest | null {
  if (!LOWERCASE_UUID_PATTERN.test(reportId)) return null;
  const query = [...url.searchParams.entries()];
  if (query.length === 0) return { reportId, format: "JSON" };
  const [entry] = query;
  if (
    query.length !== 1 ||
    entry?.[0] !== "format" ||
    (entry[1] !== "JSON" && entry[1] !== "CSV")
  ) {
    return null;
  }
  return { reportId, format: entry[1] };
}

function upstreamFailureStatus(status: number | undefined): number {
  return status === 400 ||
    status === 404 ||
    status === 422 ||
    status === 429 ||
    status === 500
    ? status
    : 503;
}

function failureResponse(status: number): Response {
  return new Response("투명성 보고서를 내려받지 못했습니다.", {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "text/plain; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

function contentDisposition(filename: string): string {
  const fallback = filename.replaceAll(/[^A-Za-z0-9._-]/gu, "_");
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}
