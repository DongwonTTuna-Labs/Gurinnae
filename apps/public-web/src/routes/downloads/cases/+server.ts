import { publicExportResponse } from "$lib/server/public-export";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = ({ fetch, url }) =>
  publicExportResponse({
    fetch,
    kind: "CASES",
    url,
    operationId: "downloadPublicCases",
    screenId: "PUB-003",
  });
