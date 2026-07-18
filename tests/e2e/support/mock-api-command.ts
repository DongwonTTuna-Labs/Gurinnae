import { randomUUID } from "node:crypto";
import { problem, runtime, sha256 } from "./mock-api-state";

export async function handleCommandRoutes(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (
    url.pathname === "/v1/internal/commands/publish-case" &&
    request.method === "POST"
  ) {
    const bytes = await request.text();
    const idempotencyKey = request.headers.get("idempotency-key") ?? "";
    const actorAssertion =
      request.headers.get("x-gurine-actor-assertion") ?? "";
    if (!idempotencyKey || !actorAssertion)
      return problem(401, "ACTOR_ASSERTION_REQUIRED");
    runtime.commandAttempts.push({
      bodySha256: sha256(bytes),
      idempotencyKeySha256: sha256(idempotencyKey),
      actorAssertionSha256: sha256(actorAssertion),
    });
    if (runtime.commandAttempts.length < 3)
      return problem(503, "UPSTREAM_TEMPORARY_FAILURE");
    return Response.json(
      {
        operationId: "publishCase",
        requestId: randomUUID(),
        status: "completed",
        aggregateId: "00000000-0000-4000-8000-000000000010",
        aggregateVersion: 2,
        auditEventId: randomUUID(),
        acceptedAt: new Date().toISOString(),
        links: [],
      },
      { status: 201 },
    );
  }
  return undefined;
}
