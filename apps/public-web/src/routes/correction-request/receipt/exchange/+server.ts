import { exchangeSubmissionToken } from "../../../submission-token-exchange";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = (event) =>
  exchangeSubmissionToken(event, {
    operationId: "exchangeCorrectionReceiptToken",
    canonicalPath: "/correction-request/receipt",
    sessionKind: "CORRECTION_RECEIPT",
  });
