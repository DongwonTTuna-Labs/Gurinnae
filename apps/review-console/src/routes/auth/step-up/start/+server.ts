import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { canonicalJsonSha256 } from "@gurine/config";
import { error, redirect } from "@sveltejs/kit";
import { readInternalSession, setStepUpTransaction } from "$lib/server/cookies";
import { identityCall, requestContext } from "$lib/server/screen";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async (event) => {
  const session = readInternalSession(event);
  if (!session) throw redirect(303, "/auth/login");
  const input: unknown = await event.request.json().catch(() => undefined);
  if (
    !isRequest(input) ||
    !constantTimeEqual(input.csrfToken, session.csrfToken)
  ) {
    throw error(403, "CSRF_TOKEN_STALE");
  }
  const returnTo = safeReturnTo(input.returnTo);
  const idempotencyKey = randomBytes(32).toString("base64url");
  const actionContext = {
    ...input.actionDescriptor,
    idempotencyKeySha256: sha256(idempotencyKey),
  };
  const result = await identityCall(
    event,
    "/internal/v1/oidc/step-up-transactions",
    {
      opaqueSessionToken: session.opaqueIdentitySessionToken,
      csrfToken: session.csrfToken,
      returnTo,
      callbackUri: new URL("/auth/step-up/callback", event.url).toString(),
      context: requestContext(event),
      actionContext,
    },
  );
  if (!result.response.ok)
    throw error(result.response.status, "STEP_UP_START_FAILED");
  const transactionCookieValue = requiredString(
    result.value.transactionCookieValue,
  );
  const authorizationUrl = requiredString(result.value.authorizationUrl);
  const issuedAt = Math.floor(Date.now() / 1000);
  setStepUpTransaction(event, {
    v: 1,
    typ: "step-up-transaction",
    transactionCookieValue,
    idempotencyKey,
    actionDigest: canonicalJsonSha256(actionContext),
    issuedAt,
    expiresAt: epochSeconds(result.value.expiresAt),
  });
  throw redirect(303, authorizationUrl);
};

type ActionDescriptor = {
  operationId: string;
  aggregateType: string;
  aggregateId: string;
  expectedVersion: number | null;
  businessPayloadSha256: string;
};
type StartRequest = {
  returnTo: string;
  actionDescriptor: ActionDescriptor;
  csrfToken: string;
};

function isRequest(value: unknown): value is StartRequest {
  if (
    !isRecord(value) ||
    typeof value.returnTo !== "string" ||
    typeof value.csrfToken !== "string" ||
    !isRecord(value.actionDescriptor)
  )
    return false;
  const action = value.actionDescriptor;
  return (
    typeof action.operationId === "string" &&
    /^[A-Za-z][A-Za-z0-9]{1,127}$/.test(action.operationId) &&
    typeof action.aggregateType === "string" &&
    /^[a-z][a-z0-9_.-]{0,127}$/.test(action.aggregateType) &&
    typeof action.aggregateId === "string" &&
    action.aggregateId.length >= 1 &&
    action.aggregateId.length <= 200 &&
    (action.expectedVersion === null ||
      (typeof action.expectedVersion === "number" &&
        Number.isSafeInteger(action.expectedVersion) &&
        action.expectedVersion >= 0)) &&
    typeof action.businessPayloadSha256 === "string" &&
    /^[a-f0-9]{64}$/.test(action.businessPayloadSha256)
  );
}
function safeReturnTo(value: string): string {
  if (
    !value.startsWith("/internal") ||
    value.startsWith("//") ||
    value.includes("\\")
  )
    throw error(400, "UNSAFE_RETURN_TARGET");
  return value;
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function requiredString(value: unknown): string {
  if (typeof value !== "string") throw error(503, "IDENTITY_RESPONSE_INVALID");
  return value;
}
function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
function epochSeconds(value: unknown): number {
  if (typeof value !== "string") throw error(503, "IDENTITY_RESPONSE_INVALID");
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds))
    throw error(503, "IDENTITY_RESPONSE_INVALID");
  return Math.floor(milliseconds / 1000);
}
function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return (
    leftBytes.length === rightBytes.length &&
    timingSafeEqual(leftBytes, rightBytes)
  );
}
