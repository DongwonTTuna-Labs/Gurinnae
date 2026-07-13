import { createHash, randomUUID } from "node:crypto";

const port = Number(process.env.MOCK_API_PORT ?? "29100");
const expiresAt = () => new Date(Date.now() + 15 * 60_000).toISOString();
const token = (seed: string) =>
  createHash("sha384").update(seed).digest("base64url");
const sha256 = (value: string) =>
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

function resetAll() {
  loginTransactions.clear();
  stepUpTransactions.clear();
  activeSession = token(`internal-session-${randomUUID()}`);
  currentCsrf = token(`csrf-${randomUUID()}`);
  sessionRevoked = false;
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
