import { randomUUID } from "node:crypto";
import {
  asserted,
  body,
  canonicalJsonSha256,
  expiresAt,
  problem,
  runtime,
  sha256,
  token,
} from "./mock-api-state";

export async function handleCoreSubmissionRoutes(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (url.pathname === "/v1/correction-session" && request.method === "POST") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const input = await body(request);
    const abuseProof = input.abuseProof;
    if (
      typeof abuseProof !== "object" ||
      abuseProof === null ||
      Array.isArray(abuseProof) ||
      (abuseProof as Record<string, unknown>).action !==
        "createCorrectionRequestDraft"
    )
      return problem(403, "ABUSE_PROOF_INVALID");
    const opaqueSessionToken = token(`correction-${randomUUID()}`);
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: "",
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json(
      {
        operationId: "createCorrectionRequestDraft",
        requestId: randomUUID(),
        status: "accepted",
        aggregateId: "88888888-8888-4888-8888-888888888888",
        aggregateVersion: runtime.correctionDraftVersion,
        acceptedAt: new Date().toISOString(),
        links: [],
        session: {
          opaqueSessionToken,
          sessionKind: "CORRECTION_DRAFT",
          scopeId: "88888888-8888-4888-8888-888888888888",
          expiresAt: expiresAt(),
          version: runtime.correctionDraftVersion,
        },
      },
      { status: 201 },
    );
  }

  if (url.pathname === "/v1/correction-session" && request.method === "PUT") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    if (input.expectedVersion !== runtime.correctionDraftVersion)
      return problem(409, "SNAPSHOT_STALE");
    runtime.correctionDraftVersion += 1;
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json({
      requestId: randomUUID(),
      status: "accepted",
      resourceId: "88888888-8888-4888-8888-888888888888",
      resourceVersion: runtime.correctionDraftVersion,
      acceptedAt: new Date().toISOString(),
    });
  }

  if (
    url.pathname === "/v1/correction-session:submit" &&
    request.method === "POST"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    if (
      input.expectedVersion !== runtime.correctionDraftVersion ||
      input.attestation !== true ||
      input.privacyConsent !== true
    )
      return problem(422, "VALIDATION_FAILED");
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json({
      operationId: "createCorrectionRequest",
      requestId: randomUUID(),
      status: "accepted",
      aggregateId: "99999999-9999-4999-8999-999999999999",
      aggregateVersion: 1,
      acceptedAt: new Date().toISOString(),
      links: [],
      receiptSession: {
        opaqueSessionToken: token(`correction-receipt-${randomUUID()}`),
        sessionKind: "CORRECTION_RECEIPT",
        scopeId: "99999999-9999-4999-8999-999999999999",
        expiresAt: expiresAt(),
        version: 1,
      },
    });
  }

  if (
    url.pathname === "/v1/response-session:verify" &&
    request.method === "POST"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    if (input.emailOtp !== "123456")
      return Response.json({
        requestId: "77777777-7777-4777-8777-777777777777",
        status: "VERIFICATION_FAILED",
        remainingAttempts: 4,
        session: {
          opaqueSessionToken: sessionToken,
          sessionKind: "RESPONSE_PENDING",
          scopeId: "77777777-7777-4777-8777-777777777777",
          expiresAt: expiresAt(),
          version: 1,
        },
      });
    return Response.json({
      requestId: "77777777-7777-4777-8777-777777777777",
      status: "VERIFIED",
      remainingAttempts: 3,
      session: {
        opaqueSessionToken: token(`response-active-${randomUUID()}`),
        sessionKind: "RESPONSE_ACTIVE",
        scopeId: "77777777-7777-4777-8777-777777777777",
        expiresAt: expiresAt(),
        version: 1,
      },
    });
  }

  const attachmentCreateKind =
    url.pathname === "/v1/response-session/attachments"
      ? "response"
      : url.pathname === "/v1/correction-session/attachments"
        ? "correction"
        : undefined;
  if (attachmentCreateKind && request.method === "POST") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    if (
      typeof input.filename !== "string" ||
      typeof input.mediaType !== "string" ||
      typeof input.sizeBytes !== "number" ||
      typeof input.sha256 !== "string" ||
      !/^[a-f0-9]{64}$/.test(input.sha256)
    )
      return problem(400, "INVALID_ATTACHMENT_METADATA");
    const id = randomUUID();
    runtime.attachmentUploads.set(id, {
      id,
      kind: attachmentCreateKind,
      filename: input.filename,
      mediaType: input.mediaType,
      sizeBytes: input.sizeBytes,
      sha256: input.sha256,
      sessionTokenSha256: sha256(sessionToken),
      uploaded: false,
      finalized: false,
    });
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json(
      {
        operationId:
          attachmentCreateKind === "response"
            ? "createResponseAttachmentUpload"
            : "createCorrectionAttachment",
        requestId: randomUUID(),
        status: "accepted",
        aggregateId: id,
        acceptedAt: new Date().toISOString(),
        links: [
          {
            rel: "upload",
            href: `/internal/submission-uploads/${id}`,
            label: "PUT attachment bytes",
          },
        ],
      },
      { status: 201 },
    );
  }

  const uploadMatch = url.pathname.match(
    /^\/internal\/submission-uploads\/([0-9a-f-]{36})$/i,
  );
  if (uploadMatch && request.method === "PUT") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const id = uploadMatch[1] ?? "";
    const target = runtime.attachmentUploads.get(id);
    if (!target) return problem(404, "ATTACHMENT_UPLOAD_TARGET_INVALID");
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (
      bytes.byteLength !== target.sizeBytes ||
      sha256(bytes) !== target.sha256 ||
      target.sessionTokenSha256 !== sha256(sessionToken)
    )
      return problem(422, "ATTACHMENT_CONTENT_MISMATCH");
    target.uploaded = true;
    return new Response(null, {
      status: 204,
      headers: { etag: `"${target.sha256}"` },
    });
  }

  const finalizeMatch = url.pathname.match(
    /^\/v1\/(response|correction)-session\/attachments\/([0-9a-f-]{36}):finalize$/i,
  );
  if (finalizeMatch && request.method === "POST") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const kind = finalizeMatch[1];
    const id = finalizeMatch[2] ?? "";
    const target = runtime.attachmentUploads.get(id);
    const input = await body(request);
    if (
      !target ||
      target.kind !== kind ||
      target.sessionTokenSha256 !== sha256(sessionToken) ||
      !target.uploaded ||
      input.uploadedSizeBytes !== target.sizeBytes ||
      input.uploadedSha256 !== target.sha256 ||
      typeof input.objectEtag !== "string"
    )
      return problem(422, "ATTACHMENT_FINALIZE_MISMATCH");
    target.finalized = true;
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json({
      operationId:
        kind === "response"
          ? "finalizeResponseAttachment"
          : "finalizeCorrectionAttachment",
      requestId: randomUUID(),
      status: "accepted",
      aggregateId: id,
      acceptedAt: new Date().toISOString(),
      links: [],
    });
  }

  const deleteAttachmentMatch = url.pathname.match(
    /^\/v1\/(response|correction)-session\/attachments\/([0-9a-f-]{36})$/i,
  );
  if (deleteAttachmentMatch && request.method === "DELETE") {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const kind = deleteAttachmentMatch[1] as "correction" | "response";
    const id = deleteAttachmentMatch[2] ?? "";
    const target = runtime.attachmentUploads.get(id);
    if (
      !target ||
      target.kind !== kind ||
      target.sessionTokenSha256 !== sha256(sessionToken)
    )
      return problem(404, "RESOURCE_NOT_FOUND");
    runtime.attachmentUploads.delete(id);
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(await body(request)),
    });
    if (kind === "response") return new Response(null, { status: 204 });
    return Response.json({
      operationId: "deleteCorrectionAttachment",
      requestId: randomUUID(),
      status: "accepted",
      aggregateId: id,
      acceptedAt: new Date().toISOString(),
      links: [],
    });
  }

  if (
    url.pathname === "/v1/response-session/draft" &&
    request.method === "PUT"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    if (
      input.expectedVersion !== runtime.responseDraftVersion ||
      !Array.isArray(input.answers) ||
      typeof input.publicationConsent !== "object" ||
      input.publicationConsent === null ||
      Array.isArray(input.publicationConsent)
    )
      return problem(409, "VERSION_CONFLICT");
    runtime.responseDraftVersion += 1;
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json({
      operationId: "saveResponseDraft",
      requestId: randomUUID(),
      status: "accepted",
      aggregateId: "77777777-7777-4777-8777-777777777777",
      aggregateVersion: runtime.responseDraftVersion,
      acceptedAt: new Date().toISOString(),
      links: [],
    });
  }

  if (
    url.pathname === "/v1/response-session:submit" &&
    request.method === "POST"
  ) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    const input = await body(request);
    if (
      input.expectedVersion !== runtime.responseDraftVersion ||
      input.attestation !== true ||
      typeof input.publicationConsent !== "object" ||
      input.publicationConsent === null ||
      Array.isArray(input.publicationConsent)
    )
      return problem(422, "VALIDATION_FAILED");
    runtime.submissionWrites.push({
      method: request.method,
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
      bodySha256: canonicalJsonSha256(input),
    });
    return Response.json(
      {
        operationId: "submitResponse",
        requestId: randomUUID(),
        status: "accepted",
        aggregateId: "66666666-6666-4666-8666-666666666666",
        aggregateVersion: 1,
        acceptedAt: new Date().toISOString(),
        links: [],
        receiptSession: {
          opaqueSessionToken: token(`response-receipt-${randomUUID()}`),
          sessionKind: "RESPONSE_RECEIPT",
          scopeId: "66666666-6666-4666-8666-666666666666",
          expiresAt: expiresAt(),
          version: 1,
        },
      },
      { status: 201 },
    );
  }
  return undefined;
}
