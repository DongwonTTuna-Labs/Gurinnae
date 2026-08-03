import { publicExportResponse } from "$lib/server/public-export";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = ({ fetch, url }) =>
  publicExportResponse({
    fetch,
    url,
    operationId: "downloadPublicSearchRecords",
    screenId: "PUB-002",
  });
