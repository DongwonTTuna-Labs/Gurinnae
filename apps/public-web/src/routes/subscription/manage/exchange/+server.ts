import { exchangeSubmissionToken } from "../../../submission-token-exchange";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = (event) =>
  exchangeSubmissionToken(event, {
    operationId: "exchangeSubscriptionManagementToken",
    canonicalPath: "/subscription/manage",
    sessionKind: "SUBSCRIPTION_MANAGEMENT",
  });
