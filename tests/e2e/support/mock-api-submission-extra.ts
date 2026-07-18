import { randomUUID } from "node:crypto";
import {
  asserted,
  body,
  canonicalJsonSha256,
  expiresAt,
  problem,
  runtime,
  token,
} from "./mock-api-state";

export async function handleExtraSubmissionRoutes(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (
    url.pathname === "/v1/subscription-session" &&
    request.method === "POST"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const input = await body(request);
    const abuseProof = input.abuseProof;
    if (
      typeof abuseProof !== "object" ||
      abuseProof === null ||
      Array.isArray(abuseProof) ||
      (abuseProof as Record<string, unknown>).action !== "createSubscription" ||
      typeof (abuseProof as Record<string, unknown>).token !== "string" ||
      !(abuseProof as Record<string, unknown>).token
        .toString()
        .startsWith("gurine-synth-v1.") ||
      input.consent !== true
    )
      return problem(403, "ABUSE_PROOF_INVALID");
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: "",
      bodySha256: canonicalJsonSha256(input),
      ...(typeof input.scopeType === "string"
        ? { scopeType: input.scopeType }
        : {}),
      ...(typeof input.scopeRef === "string"
        ? { scopeRef: input.scopeRef }
        : {}),
    });
    return Response.json(
      {
        operationId: "createSubscription",
        requestId: randomUUID(),
        status: "accepted",
        aggregateId: "55555555-5555-4555-8555-555555555555",
        aggregateVersion: 1,
        acceptedAt: new Date().toISOString(),
        links: [],
        verificationDispatched: true,
        pendingSession: {
          opaqueSessionToken: token(`subscription-pending-${randomUUID()}`),
          sessionKind: "SUBSCRIPTION_PENDING",
          scopeId: "55555555-5555-4555-8555-555555555555",
          expiresAt: expiresAt(),
          version: 1,
        },
      },
      { status: 201 },
    );
  }

  if (url.pathname === "/v1/dataset-exports" && request.method === "POST") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const input = await body(request);
    const abuseProof = input.abuseProof;
    if (
      typeof input.datasetId !== "string" ||
      !["CSV", "JSONL", "PARQUET"].includes(String(input.format)) ||
      typeof input.filters !== "object" ||
      input.filters === null ||
      Array.isArray(input.filters) ||
      typeof input.expiresInSeconds !== "number" ||
      typeof abuseProof !== "object" ||
      abuseProof === null ||
      Array.isArray(abuseProof) ||
      (abuseProof as Record<string, unknown>).action !== "createDatasetExport"
    )
      return problem(400, "INVALID_DATASET_EXPORT");
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: "",
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json(
      {
        operationId: "createDatasetExport",
        requestId: randomUUID(),
        status: "accepted",
        aggregateId: randomUUID(),
        receiptToken: token(`dataset-export-${randomUUID()}`),
        acceptedAt: new Date().toISOString(),
        links: [],
      },
      { status: 202 },
    );
  }

  if (
    url.pathname === "/v1/submission-session/subscription:verify" &&
    request.method === "POST"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const input = await body(request);
    const verificationToken =
      typeof input.verificationToken === "string"
        ? input.verificationToken
        : "";
    if (!verificationToken) return problem(400, "VERIFICATION_TOKEN_REQUIRED");
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: "",
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json({
      subscriptionId: "55555555-5555-4555-8555-555555555555",
      status: "VERIFIED",
      session: {
        opaqueSessionToken: token(`subscription-active-${randomUUID()}`),
        sessionKind: "SUBSCRIPTION_MANAGEMENT",
        scopeId: "55555555-5555-4555-8555-555555555555",
        expiresAt: expiresAt(),
        version: 1,
      },
    });
  }
  return undefined;
}
