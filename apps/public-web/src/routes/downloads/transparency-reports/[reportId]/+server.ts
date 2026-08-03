import { transparencyReportResponse } from "$lib/server/transparency-report-response";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = ({ fetch, params, url }) =>
  transparencyReportResponse({ fetch, reportId: params.reportId, url });
