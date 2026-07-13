import { createHash } from "node:crypto";
import { redirect } from "@sveltejs/kit";
import {
  clearStepUpAuthorization,
  clearStepUpState,
  readInternalSession,
  readPending,
  readStepUpTransaction,
  setInternalSession,
  setStepUpAuthorization,
} from "$lib/server/cookies";
import {
  executePending,
  identityCall,
  requestContext,
} from "$lib/server/screen";
import type { RequestHandler } from "./$types";

type Pending = Parameters<typeof executePending>[1];

export const GET: RequestHandler = async (event) => {
  const transaction = readStepUpTransaction(event);
  const pending = readPending(event, isPending);
  const session = readInternalSession(event);
  const code = event.url.searchParams.get("code");
  const state = event.url.searchParams.get("state");
  if (!transaction || !session || !code || !state)
    throw redirect(303, "/auth/access-denied");
  const result = await identityCall(
    event,
    "/internal/v1/oidc/step-up-callbacks",
    {
      opaqueSessionToken: session.opaqueIdentitySessionToken,
      transactionCookieValue: transaction.transactionCookieValue,
      code,
      state,
      issuer: event.url.searchParams.get("iss"),
      context: requestContext(event),
    },
  );
  if (!result.response.ok) throw redirect(303, "/auth/access-denied");
  const elevated = {
    actionDigest: requiredString(result.value.actionDigest),
    stepUpAuthorizationToken: requiredString(
      result.value.stepUpAuthorizationToken,
    ),
    idempotencyKeySha256: requiredString(result.value.idempotencyKeySha256),
    csrfToken: requiredString(result.value.csrfToken),
  };
  if (
    elevated.actionDigest !== transaction.actionDigest ||
    elevated.idempotencyKeySha256 !== sha256(transaction.idempotencyKey)
  ) {
    throw redirect(303, "/auth/access-denied");
  }
  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = epochSeconds(result.value.expiresAt);
  setInternalSession(event, {
    ...session,
    csrfToken: elevated.csrfToken,
    csrfRotatedAt: issuedAt,
  });
  setStepUpAuthorization(event, {
    v: 1,
    typ: "step-up-authorization",
    authorizationId: requiredString(result.value.stepUpAuthorizationId),
    authorizationToken: elevated.stepUpAuthorizationToken,
    actionDigest: elevated.actionDigest,
    idempotencyKey: transaction.idempotencyKey,
    idempotencyKeySha256: elevated.idempotencyKeySha256,
    maxAssertionIssues: 3,
    issuedAt,
    expiresAt,
  });
  if (!pending) {
    clearStepUpState(event);
    const returnTo = requiredString(result.value.returnTo);
    throw redirect(
      303,
      returnTo.startsWith("/internal") && !returnTo.startsWith("//")
        ? returnTo
        : "/internal/dashboard",
    );
  }
  const control = await executePending(event, pending, elevated);
  clearStepUpState(event);
  if (![502, 503, 504].includes(control.response.status))
    clearStepUpAuthorization(event);
  const notice = control.response.ok
    ? `${pending.operationId} 완료`
    : `${pending.operationId} 실패`;
  throw redirect(
    303,
    `${pending.returnTo}?notice=${encodeURIComponent(notice)}`,
  );
};

function requiredString(value: unknown): string {
  if (typeof value !== "string")
    throw new Error("step-up callback response is incomplete");
  return value;
}

function isPending(value: unknown): value is Pending {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.operationId === "string" &&
    typeof item.path === "string" &&
    typeof item.bodyBytes === "string" &&
    typeof item.idempotencyKey === "string" &&
    typeof item.returnTo === "string" &&
    typeof item.body === "object" &&
    item.body !== null &&
    typeof item.actionContext === "object" &&
    item.actionContext !== null
  );
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function epochSeconds(value: unknown): number {
  if (typeof value !== "string") throw new Error("step-up expiry is missing");
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds))
    throw new Error("step-up expiry is invalid");
  return Math.floor(milliseconds / 1000);
}
