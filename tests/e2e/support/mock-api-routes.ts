import { handleAuthRoutes } from "./mock-api-auth";
import { handleCommandRoutes } from "./mock-api-command";
import { handleDonationMock } from "./mock-api-donation";
import { validateMockResponse } from "./mock-api-openapi";
import { handleProviderProposalCommands } from "./mock-api-provider-proposal-command";
import { handleProviderProposalReads } from "./mock-api-provider-proposal-routes";
import { handleReadRoutes } from "./mock-api-reads";
import {
  asserted,
  clearObservations,
  problem,
  resetAll,
  testState,
} from "./mock-api-state";
import { handleCoreSubmissionRoutes } from "./mock-api-submission-core";
import { handleExtraSubmissionRoutes } from "./mock-api-submission-extra";

export async function handleMockRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  let response: Response;
  if (url.pathname === "/health/ready" && request.method === "GET")
    response = Response.json({ status: "ready" });
  else if (url.pathname === "/_test/state" && request.method === "GET")
    response = Response.json(testState());
  else if (url.pathname === "/_test/reset" && request.method === "POST") {
    resetAll();
    response = Response.json({ reset: true });
  } else if (
    url.pathname === "/_test/clear-observations" &&
    request.method === "POST"
  ) {
    clearObservations();
    response = Response.json({ reset: true });
  } else if (url.pathname.startsWith("/internal/v1/") && !asserted(request)) {
    response = problem(401, "SERVICE_ASSERTION_REQUIRED");
  } else {
    response =
      (await handleAuthRoutes(request, url)) ??
      (await handleDonationMock(request, url)) ??
      (await handleProviderProposalCommands(request, url)) ??
      (await handleCommandRoutes(request, url)) ??
      (await handleCoreSubmissionRoutes(request, url)) ??
      (await handleExtraSubmissionRoutes(request, url)) ??
      (await handleProviderProposalReads(request, url)) ??
      (await handleReadRoutes(request, url));
  }
  return validateMockResponse(request, response);
}
