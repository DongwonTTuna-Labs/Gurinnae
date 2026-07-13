import { createHash, randomUUID } from "node:crypto";

const port = Number(process.env.MOCK_API_PORT ?? "29100");
const expiresAt = () => new Date(Date.now() + 15 * 60_000).toISOString();
const token = (seed: string) =>
  createHash("sha384").update(seed).digest("base64url");
const sha256 = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const canonicalJsonSha256 = (value: unknown) =>
  sha256(JSON.stringify(sortJson(value)));

type LoginTransaction = { returnTo: string; callbackUri: string };
type StepUpTransaction = {
  returnTo: string;
  callbackUri: string;
  actionContext: Record<string, unknown>;
};
type CommandAttempt = {
  bodySha256: string;
  idempotencyKeySha256: string;
  actorAssertionSha256: string;
};
type AttachmentUpload = {
  id: string;
  kind: "correction" | "response";
  filename: string;
  mediaType: string;
  sizeBytes: number;
  sha256: string;
  sessionTokenSha256: string;
  uploaded: boolean;
  finalized: boolean;
};

const loginTransactions = new Map<string, LoginTransaction>();
const stepUpTransactions = new Map<string, StepUpTransaction>();
let activeSession = token("internal-session");
let currentCsrf = token("csrf-initial");
let sessionRevoked = false;
let actorAssertionSerial = 0;
let sessionResolveCount = 0;
let stepUpStartCount = 0;
let stepUpCallbackCount = 0;
let authorizationCloseCount = 0;
let sessionRevokeCount = 0;
let commandAttempts: CommandAttempt[] = [];
let assertionOperations: Array<{
  operationId: string;
  actorAssertionSha256: string;
}> = [];
const submissionExchanges: Array<{
  path: string;
  tokenSha256: string;
  sessionKind: string;
  idempotencyKeySha256: string;
  accepted: boolean;
}> = [];
const consumedOneTimeTokens = new Set<string>();
const exchangeReplays = new Map<
  string,
  { bodySha256: string; response: Record<string, unknown> }
>();
const submissionReads: Array<{ path: string; sessionTokenSha256: string }> = [];
const submissionWrites: Array<{
  method: string;
  path: string;
  sessionTokenSha256: string;
  bodySha256: string;
}> = [];
const attachmentUploads = new Map<string, AttachmentUpload>();
let correctionDraftVersion = 1;
let responseDraftVersion = 3;

function resetAll() {
  loginTransactions.clear();
  stepUpTransactions.clear();
  activeSession = token(`internal-session-${randomUUID()}`);
  currentCsrf = token(`csrf-${randomUUID()}`);
  sessionRevoked = false;
  consumedOneTimeTokens.clear();
  exchangeReplays.clear();
  clearObservations();
}

function clearObservations() {
  actorAssertionSerial = 0;
  sessionResolveCount = 0;
  stepUpStartCount = 0;
  stepUpCallbackCount = 0;
  authorizationCloseCount = 0;
  sessionRevokeCount = 0;
  commandAttempts = [];
  assertionOperations = [];
}

function actor() {
  return {
    actorId: "00000000-0000-4000-8000-000000000001",
    subject: "e2e-reviewer",
    displayName: "E2E 검토자",
    roles: ["administrator", "publisher"],
    capabilities: [
      "publication.publish",
      "cases.investigate",
      "review.editorial",
      "sources.operate",
      "kill_switch.execute",
      "admin.users.manage",
      "admin.roles.manage",
      "audit.export",
    ],
  };
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortJson(item)]),
  );
}

function problem(status: number, code: string, title = code) {
  return Response.json(
    { type: "about:blank", title, status, code },
    { status, headers: { "content-type": "application/problem+json" } },
  );
}

function attachmentStatus(item: AttachmentUpload) {
  return {
    id: item.id,
    filename: item.filename,
    mediaType: item.mediaType,
    sizeBytes: item.sizeBytes,
    sha256: item.sha256,
    uploadStatus: item.finalized ? "FINALIZED" : "PENDING",
    scanStatus: item.finalized ? "PENDING" : "NOT_STARTED",
    publicationConsent: false,
  };
}

async function body(request: Request): Promise<Record<string, unknown>> {
  const value: unknown = await request.json().catch(() => undefined);
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function asserted(request: Request): boolean {
  const assertion = request.headers.get("x-gurine-service-assertion");
  return (
    assertion?.startsWith("gurine-sa-v1.") === true &&
    Boolean(request.headers.get("x-request-id"))
  );
}

function callbackUrl(callbackUri: string, kind: "login" | "step-up") {
  const url = new URL(callbackUri);
  url.searchParams.set("code", `${kind}-code`);
  url.searchParams.set("state", `${kind}-state`);
  url.searchParams.set("iss", "https://synthetic-idp.invalid");
  return url.toString();
}

function testState() {
  return {
    sessionResolveCount,
    stepUpStartCount,
    stepUpCallbackCount,
    authorizationCloseCount,
    sessionRevokeCount,
    sessionRevoked,
    commandAttempts,
    assertionOperations,
    submissionExchanges,
    submissionReads,
    submissionWrites,
    attachmentUploads: [...attachmentUploads.values()],
  };
}

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
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

    if (url.pathname.startsWith("/internal/v1/") && !asserted(request)) {
      return problem(401, "SERVICE_ASSERTION_REQUIRED");
    }

    if (
      url.pathname === "/internal/v1/oidc/login-transactions" &&
      request.method === "POST"
    ) {
      const input = await body(request);
      const transactionCookieValue = token(`login-${randomUUID()}`);
      const returnTo =
        typeof input.returnTo === "string"
          ? input.returnTo
          : "/internal/dashboard";
      const callbackUri =
        typeof input.callbackUri === "string" ? input.callbackUri : "";
      loginTransactions.set(transactionCookieValue, { returnTo, callbackUri });
      return Response.json({
        transactionCookieValue,
        authorizationUrl: callbackUrl(callbackUri, "login"),
        expiresAt: expiresAt(),
        sameSite: "Lax",
        httpOnly: true,
        secure: false,
        path: "/auth/callback",
        domainMode: "HOST_ONLY",
      });
    }

    if (
      url.pathname === "/internal/v1/oidc/login-callbacks" &&
      request.method === "POST"
    ) {
      const input = await body(request);
      const transaction =
        typeof input.transactionCookieValue === "string"
          ? loginTransactions.get(input.transactionCookieValue)
          : undefined;
      if (
        !transaction ||
        input.code !== "login-code" ||
        input.state !== "login-state"
      ) {
        return problem(409, "OIDC_TRANSACTION_INVALID");
      }
      loginTransactions.delete(input.transactionCookieValue as string);
      return Response.json({
        opaqueSessionToken: activeSession,
        csrfToken: currentCsrf,
        returnTo: transaction.returnTo,
        expiresAt: expiresAt(),
        actor: actor(),
        sessionCookiePath: "/",
        sessionCookieDomainMode: "HOST_ONLY",
        sessionCookieSameSite: "Lax",
        csrfStorage: "SEALED_BFF_SESSION_SYNCHRONIZER",
      });
    }

    if (
      url.pathname === "/internal/v1/sessions/resolve" &&
      request.method === "POST"
    ) {
      sessionResolveCount += 1;
      const input = await body(request);
      if (sessionRevoked || input.opaqueSessionToken !== activeSession) {
        return problem(401, "SESSION_NOT_ACTIVE");
      }
      return Response.json({
        actor: actor(),
        sessionExpiresAt: expiresAt(),
        assuranceLevel: "ACTIVE_SESSION",
      });
    }

    if (
      url.pathname === "/internal/v1/sessions/revoke" &&
      request.method === "POST"
    ) {
      const input = await body(request);
      if (input.opaqueSessionToken !== activeSession)
        return problem(401, "SESSION_NOT_ACTIVE");
      sessionRevokeCount += 1;
      sessionRevoked = true;
      return Response.json({
        revoked: true,
        revokedAt: new Date().toISOString(),
      });
    }

    if (
      url.pathname === "/internal/v1/oidc/step-up-transactions" &&
      request.method === "POST"
    ) {
      stepUpStartCount += 1;
      const input = await body(request);
      if (
        input.opaqueSessionToken !== activeSession ||
        input.csrfToken !== currentCsrf
      ) {
        return problem(403, "CSRF_TOKEN_STALE");
      }
      if (
        typeof input.callbackUri !== "string" ||
        typeof input.returnTo !== "string" ||
        typeof input.actionContext !== "object" ||
        input.actionContext === null ||
        Array.isArray(input.actionContext)
      ) {
        return problem(400, "INVALID_REQUEST");
      }
      const transactionCookieValue = token(`step-up-${randomUUID()}`);
      stepUpTransactions.set(transactionCookieValue, {
        callbackUri: input.callbackUri,
        returnTo: input.returnTo,
        actionContext: input.actionContext as Record<string, unknown>,
      });
      return Response.json({
        transactionCookieValue,
        authorizationUrl: callbackUrl(input.callbackUri, "step-up"),
        expiresAt: expiresAt(),
        sameSite: "Lax",
        httpOnly: true,
        secure: false,
        path: "/auth/step-up/callback",
        domainMode: "HOST_ONLY",
      });
    }

    if (
      url.pathname === "/internal/v1/oidc/step-up-callbacks" &&
      request.method === "POST"
    ) {
      stepUpCallbackCount += 1;
      const input = await body(request);
      const transaction =
        typeof input.transactionCookieValue === "string"
          ? stepUpTransactions.get(input.transactionCookieValue)
          : undefined;
      if (
        !transaction ||
        input.opaqueSessionToken !== activeSession ||
        input.code !== "step-up-code" ||
        input.state !== "step-up-state"
      ) {
        return problem(409, "STEP_UP_TRANSACTION_INVALID");
      }
      stepUpTransactions.delete(input.transactionCookieValue as string);
      currentCsrf = token(`csrf-rotated-${randomUUID()}`);
      return Response.json({
        stepUpAuthorizationId: randomUUID(),
        stepUpAuthorizationToken: token(`authorization-${randomUUID()}`),
        actionDigest: canonicalJsonSha256(transaction.actionContext),
        idempotencyKeySha256: transaction.actionContext.idempotencyKeySha256,
        returnTo: transaction.returnTo,
        expiresAt: expiresAt(),
        maxAssertionIssues: 3,
        csrfToken: currentCsrf,
        authorizationCookiePath: "/internal",
        authorizationCookieDomainMode: "HOST_ONLY",
        authorizationCookieSameSite: "Strict",
      });
    }

    if (
      url.pathname === "/internal/v1/actor-assertions" &&
      request.method === "POST"
    ) {
      const input = await body(request);
      if (input.opaqueSessionToken !== activeSession)
        return problem(401, "SESSION_NOT_ACTIVE");
      actorAssertionSerial += 1;
      const actorAssertion = `gurine-aa-v1.${"a".repeat(16)}.${token(`payload-${actorAssertionSerial}`)}.${token(`signature-${actorAssertionSerial}`).slice(0, 43)}`;
      const operationId =
        typeof input.operationId === "string" ? input.operationId : "unknown";
      assertionOperations.push({
        operationId,
        actorAssertionSha256: sha256(actorAssertion),
      });
      return Response.json({
        actor: actor(),
        actorAssertion,
        assertionExpiresAt: new Date(Date.now() + 30_000).toISOString(),
        stepUpAuthorizationId: input.stepUpAuthorizationToken
          ? "00000000-0000-4000-8000-000000000002"
          : null,
        remainingAssertionIssues: input.stepUpAuthorizationToken
          ? Math.max(0, 3 - actorAssertionSerial)
          : null,
        assuranceLevel: input.stepUpAuthorizationToken
          ? "STEP_UP"
          : "ACTIVE_SESSION",
      });
    }

    if (
      url.pathname === "/internal/v1/step-up-authorizations/close" &&
      request.method === "POST"
    ) {
      authorizationCloseCount += 1;
      return Response.json({
        closed: true,
        closedAt: new Date().toISOString(),
      });
    }

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
      commandAttempts.push({
        bodySha256: sha256(bytes),
        idempotencyKeySha256: sha256(idempotencyKey),
        actorAssertionSha256: sha256(actorAssertion),
      });
      if (commandAttempts.length < 3)
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

    if (
      url.pathname === "/v1/correction-session" &&
      request.method === "POST"
    ) {
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
      submissionWrites.push({
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
          aggregateVersion: correctionDraftVersion,
          acceptedAt: new Date().toISOString(),
          links: [],
          session: {
            opaqueSessionToken,
            sessionKind: "CORRECTION_DRAFT",
            scopeId: "88888888-8888-4888-8888-888888888888",
            expiresAt: expiresAt(),
            version: correctionDraftVersion,
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
      if (input.expectedVersion !== correctionDraftVersion)
        return problem(409, "SNAPSHOT_STALE");
      correctionDraftVersion += 1;
      submissionWrites.push({
        method: request.method,
        path: url.pathname,
        sessionTokenSha256: sha256(sessionToken),
        bodySha256: canonicalJsonSha256(input),
      });
      return Response.json({
        requestId: randomUUID(),
        status: "accepted",
        resourceId: "88888888-8888-4888-8888-888888888888",
        resourceVersion: correctionDraftVersion,
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
        input.expectedVersion !== correctionDraftVersion ||
        input.attestation !== true ||
        input.privacyConsent !== true
      )
        return problem(422, "VALIDATION_FAILED");
      submissionWrites.push({
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
      submissionWrites.push({
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
      attachmentUploads.set(id, {
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
      submissionWrites.push({
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
      const target = attachmentUploads.get(id);
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
      const target = attachmentUploads.get(id);
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
      submissionWrites.push({
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
      const target = attachmentUploads.get(id);
      if (
        !target ||
        target.kind !== kind ||
        target.sessionTokenSha256 !== sha256(sessionToken)
      )
        return problem(404, "RESOURCE_NOT_FOUND");
      attachmentUploads.delete(id);
      submissionWrites.push({
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
        input.expectedVersion !== responseDraftVersion ||
        !Array.isArray(input.answers) ||
        typeof input.publicationConsent !== "object" ||
        input.publicationConsent === null ||
        Array.isArray(input.publicationConsent)
      )
        return problem(409, "VERSION_CONFLICT");
      responseDraftVersion += 1;
      submissionWrites.push({
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
        aggregateVersion: responseDraftVersion,
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
        input.expectedVersion !== responseDraftVersion ||
        input.attestation !== true ||
        typeof input.publicationConsent !== "object" ||
        input.publicationConsent === null ||
        Array.isArray(input.publicationConsent)
      )
        return problem(422, "VALIDATION_FAILED");
      submissionWrites.push({
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
        (abuseProof as Record<string, unknown>).action !==
          "createSubscription" ||
        input.consent !== true
      )
        return problem(403, "ABUSE_PROOF_INVALID");
      submissionWrites.push({
        method: request.method,
        path: url.pathname,
        sessionTokenSha256: "",
        bodySha256: canonicalJsonSha256(input),
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
      submissionWrites.push({
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
      if (!verificationToken)
        return problem(400, "VERIFICATION_TOKEN_REQUIRED");
      submissionWrites.push({
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

    const exchangeKinds: Record<string, string> = {
      "/v1/submission-session/response:exchange": "RESPONSE_PENDING",
      "/v1/submission-session/response-receipt:exchange": "RESPONSE_RECEIPT",
      "/v1/submission-session/correction-receipt:exchange":
        "CORRECTION_RECEIPT",
      "/v1/submission-session/subscription-management:exchange":
        "SUBSCRIPTION_MANAGEMENT",
    };
    const exchangeKind = exchangeKinds[url.pathname];
    if (exchangeKind && request.method === "POST") {
      if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
      const input = await body(request);
      const idempotencyKey = request.headers.get("idempotency-key") ?? "";
      if (!idempotencyKey) return problem(400, "IDEMPOTENCY_KEY_REQUIRED");
      const replayKey = `${url.pathname}\0${idempotencyKey}`;
      const bodySha256 = canonicalJsonSha256(input);
      const replay = exchangeReplays.get(replayKey);
      if (replay) {
        if (replay.bodySha256 !== bodySha256)
          return problem(409, "IDEMPOTENCY_REQUEST_CONFLICT");
        return Response.json(replay.response, {
          headers: { "idempotent-replay": "true" },
        });
      }
      const oneTimeToken =
        typeof input.oneTimeToken === "string" ? input.oneTimeToken : "";
      if (!oneTimeToken) return problem(400, "ONE_TIME_TOKEN_REQUIRED");
      if (oneTimeToken.startsWith("invalid-"))
        return problem(401, "ONE_TIME_TOKEN_INVALID");
      const observation = {
        path: url.pathname,
        tokenSha256: sha256(oneTimeToken),
        sessionKind: exchangeKind,
        idempotencyKeySha256: sha256(idempotencyKey),
      };
      if (consumedOneTimeTokens.has(oneTimeToken)) {
        submissionExchanges.push({ ...observation, accepted: false });
        return problem(401, "ONE_TIME_TOKEN_INVALID");
      }
      consumedOneTimeTokens.add(oneTimeToken);
      const opaqueSessionToken = token(
        `submission-${exchangeKind}-${oneTimeToken}`,
      );
      submissionExchanges.push({ ...observation, accepted: true });
      const response = {
        status: "exchanged",
        session: {
          opaqueSessionToken,
          sessionKind: exchangeKind,
          scopeId: "77777777-7777-4777-8777-777777777777",
          expiresAt: expiresAt(),
          version: 1,
        },
      };
      exchangeReplays.set(replayKey, { bodySha256, response });
      return Response.json(response);
    }

    const submissionReadPaths = new Set([
      "/v1/response-session/access-status",
      "/v1/response-session",
      "/v1/response-session/draft",
      "/v1/response-session/download",
      "/v1/response-session/preview",
      "/v1/response-receipt",
      "/v1/correction-session",
      "/v1/correction-session/preview",
      "/v1/correction-receipt",
      "/v1/subscription-session",
    ]);
    if (request.method === "GET" && submissionReadPaths.has(url.pathname)) {
      if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
      const sessionToken =
        request.headers.get("x-gurine-submission-session") ?? "";
      if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
      submissionReads.push({
        path: url.pathname,
        sessionTokenSha256: sha256(sessionToken),
      });
      if (url.pathname === "/v1/response-session/download") {
        return Response.json({
          binary: btoa(
            JSON.stringify({
              requestId: "77777777-7777-4777-8777-777777777777",
              status: "READY",
            }),
          ),
        });
      }
      if (url.pathname === "/v1/response-session/draft") {
        const attachments = [...attachmentUploads.values()]
          .filter(
            (item) =>
              item.kind === "response" &&
              item.sessionTokenSha256 === sha256(sessionToken),
          )
          .map(attachmentStatus);
        return Response.json({
          requestId: "77777777-7777-4777-8777-777777777777",
          version: responseDraftVersion,
          answers: [],
          attachments,
          publicationConsent: {
            body: false,
            attachments: [],
            redactionAcknowledged: false,
            scopeExplanation: "아직 공개 동의를 확정하지 않았습니다.",
            updatedAt: new Date().toISOString(),
          },
          savedAt: new Date().toISOString(),
          expiresAt: expiresAt(),
        });
      }
      if (url.pathname === "/v1/response-session/preview") {
        return Response.json({
          request: {
            requestId: "77777777-7777-4777-8777-777777777777",
            casePublicTitle: "E2E 공개 사건",
            partyName: "E2E 응답 기관",
            status: "OPEN",
            dueAt: expiresAt(),
            questionCount: 1,
          },
          answers: [],
          attachments: [],
          publicationConsent: {
            body: true,
            attachments: [],
            redactionAcknowledged: true,
            scopeExplanation: "본문 공개에 동의합니다.",
            updatedAt: new Date().toISOString(),
          },
          warnings: [],
          submissionDigest: "b".repeat(64),
        });
      }
      if (url.pathname === "/v1/correction-session") {
        return Response.json({
          id: "88888888-8888-4888-8888-888888888888",
          version: correctionDraftVersion,
          requesterType: "CITIZEN",
          contactEmail: "requester@example.test",
          summary: "공개 문장의 수치를 바로잡아 주세요.",
          requestedChanges: ["계약 금액을 원문과 일치시켜 주세요."],
          evidenceDescription: "공개 원문 링크를 확인했습니다.",
        });
      }
      if (url.pathname === "/v1/correction-session/preview") {
        const attachments = [...attachmentUploads.values()]
          .filter(
            (item) =>
              item.kind === "correction" &&
              item.sessionTokenSha256 === sha256(sessionToken),
          )
          .map(attachmentStatus);
        return Response.json({
          draft: {
            id: "88888888-8888-4888-8888-888888888888",
            version: correctionDraftVersion,
          },
          attachments,
          warnings: [],
          submissionDigest: "a".repeat(64),
        });
      }
      return Response.json({
        id: "77777777-7777-4777-8777-777777777777",
        status: "READY",
        version: 1,
        items: [],
        links: [],
      });
    }

    if (request.method === "GET") {
      if (url.pathname === "/v1/internal/queries/get-publish-confirmation") {
        return Response.json({
          id: "00000000-0000-4000-8000-000000000020",
          status: "ready",
          data: {
            caseId: "00000000-0000-4000-8000-000000000010",
            snapshotId: "00000000-0000-4000-8000-000000000020",
            previewHash: "b".repeat(64),
            currentCaseVersion: 1,
            requiredReauth: true,
            impactSummary: ["공개 projection과 알림이 갱신됩니다."],
            publicUrls: ["/cases/e2e-case"],
          },
          links: [],
        });
      }
      return Response.json({
        items: [],
        appliedFilters: Object.fromEntries(url.searchParams),
        asOf: "2026-07-12T00:00:00Z",
        nextCursor: null,
      });
    }
    return problem(409, "SYNTHETIC_READ_ONLY", "Synthetic mutation disabled");
  },
});
