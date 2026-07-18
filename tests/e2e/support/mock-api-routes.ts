import { handleAuthRoutes } from "./mock-api-auth";
import { handleCommandRoutes } from "./mock-api-command";
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
  if (url.pathname === "/health/ready")
    return Response.json({ status: "ready" });
  if (url.pathname === "/_test/state") return Response.json(testState());
  if (url.pathname === "/_test/reset" && request.method === "POST") {
    resetAll();
    return Response.json({ reset: true });
  }
  if (
    url.pathname === "/_test/clear-observations" &&
    request.method === "POST"
  ) {
    clearObservations();
    return Response.json({ reset: true });
  }
  if (url.pathname.startsWith("/internal/v1/") && !asserted(request))
    return problem(401, "SERVICE_ASSERTION_REQUIRED");
  return (
    (await handleAuthRoutes(request, url)) ??
    (await handleCommandRoutes(request, url)) ??
    (await handleCoreSubmissionRoutes(request, url)) ??
    (await handleExtraSubmissionRoutes(request, url)) ??
    (await handleReadRoutes(request, url))
  );
}
