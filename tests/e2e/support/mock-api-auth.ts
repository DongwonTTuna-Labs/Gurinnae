import { randomUUID } from "node:crypto";
import {
  actor,
  body,
  callbackUrl,
  canonicalJsonSha256,
  expiresAt,
  problem,
  runtime,
  sha256,
  token,
} from "./mock-api-state";

export async function handleAuthRoutes(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
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
    runtime.loginTransactions.set(transactionCookieValue, {
      returnTo,
      callbackUri,
    });
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
        ? runtime.loginTransactions.get(input.transactionCookieValue)
        : undefined;
    if (
      !transaction ||
      input.code !== "login-code" ||
      input.state !== "login-state"
    ) {
      return problem(409, "OIDC_TRANSACTION_INVALID");
    }
    runtime.loginTransactions.delete(input.transactionCookieValue as string);
    return Response.json({
      opaqueSessionToken: runtime.activeSession,
      csrfToken: runtime.currentCsrf,
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
    runtime.sessionResolveCount += 1;
    const input = await body(request);
    if (
      runtime.sessionRevoked ||
      input.opaqueSessionToken !== runtime.activeSession
    ) {
      return problem(401, "SESSION_NOT_ACTIVE");
    }
    const now = new Date().toISOString();
    return Response.json({
      actor: actor(),
      sessionExpiresAt: expiresAt(),
      stepUpAt: null,
      csrfRotatedAt: now,
      csrfTokenReturned: false,
    });
  }

  if (
    url.pathname === "/internal/v1/sessions/revoke" &&
    request.method === "POST"
  ) {
    const input = await body(request);
    if (input.opaqueSessionToken !== runtime.activeSession)
      return problem(401, "SESSION_NOT_ACTIVE");
    runtime.sessionRevokeCount += 1;
    runtime.sessionRevoked = true;
    return Response.json({
      revoked: true,
      revokedAt: new Date().toISOString(),
      auditEventId: randomUUID(),
    });
  }

  if (
    url.pathname === "/internal/v1/oidc/step-up-transactions" &&
    request.method === "POST"
  ) {
    runtime.stepUpStartCount += 1;
    const input = await body(request);
    if (
      input.opaqueSessionToken !== runtime.activeSession ||
      input.csrfToken !== runtime.currentCsrf
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
    runtime.stepUpTransactions.set(transactionCookieValue, {
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
    runtime.stepUpCallbackCount += 1;
    const input = await body(request);
    const transaction =
      typeof input.transactionCookieValue === "string"
        ? runtime.stepUpTransactions.get(input.transactionCookieValue)
        : undefined;
    if (
      !transaction ||
      input.opaqueSessionToken !== runtime.activeSession ||
      input.code !== "step-up-code" ||
      input.state !== "step-up-state"
    ) {
      return problem(409, "STEP_UP_TRANSACTION_INVALID");
    }
    runtime.stepUpTransactions.delete(input.transactionCookieValue as string);
    runtime.currentCsrf = token(`csrf-rotated-${randomUUID()}`);
    return Response.json({
      stepUpAuthorizationId: randomUUID(),
      stepUpAuthorizationToken: token(`authorization-${randomUUID()}`),
      actionDigest: canonicalJsonSha256(transaction.actionContext),
      idempotencyKeySha256: transaction.actionContext.idempotencyKeySha256,
      returnTo: transaction.returnTo,
      expiresAt: expiresAt(),
      maxAssertionIssues: 3,
      csrfToken: runtime.currentCsrf,
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
    if (input.opaqueSessionToken !== runtime.activeSession)
      return problem(401, "SESSION_NOT_ACTIVE");
    runtime.actorAssertionSerial += 1;
    const actorAssertion = `gurine-aa-v1.${"a".repeat(16)}.${token(`payload-${runtime.actorAssertionSerial}`)}.${token(`signature-${runtime.actorAssertionSerial}`).slice(0, 43)}`;
    const operationId =
      typeof input.operationId === "string" ? input.operationId : "unknown";
    runtime.assertionOperations.push({
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
        ? Math.max(0, 3 - runtime.actorAssertionSerial)
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
    runtime.authorizationCloseCount += 1;
    return Response.json({
      closed: true,
      closedAt: new Date().toISOString(),
    });
  }
  return undefined;
}
