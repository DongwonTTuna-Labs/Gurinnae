import { redirect } from "@sveltejs/kit";
import {
  clearLoginTransaction,
  OIDC_TRANSACTION_COOKIE,
  setInternalSession,
} from "$lib/server/cookies";
import { identityCall, requestContext } from "$lib/server/screen";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async (event) => {
  const transaction = event.cookies.get(OIDC_TRANSACTION_COOKIE);
  const code = event.url.searchParams.get("code");
  const state = event.url.searchParams.get("state");
  if (!transaction || !code || !state)
    throw redirect(303, "/auth/access-denied");
  const result = await identityCall(
    event,
    "/internal/v1/oidc/login-callbacks",
    {
      transactionCookieValue: transaction,
      code,
      state,
      issuer: event.url.searchParams.get("iss"),
      context: requestContext(event),
    },
  );
  clearLoginTransaction(event);
  if (!result.response.ok) throw redirect(303, "/auth/access-denied");
  const session = result.value.opaqueSessionToken;
  const csrf = result.value.csrfToken;
  const returnTo = result.value.returnTo;
  if (
    typeof session !== "string" ||
    typeof csrf !== "string" ||
    typeof returnTo !== "string"
  ) {
    throw redirect(303, "/auth/access-denied");
  }
  const issuedAt = Math.floor(Date.now() / 1000);
  const absoluteExpiresAt = epochSeconds(result.value.expiresAt);
  setInternalSession(event, {
    v: 1,
    typ: "internal-session",
    opaqueIdentitySessionToken: session,
    csrfToken: csrf,
    issuedAt,
    absoluteExpiresAt,
    csrfRotatedAt: issuedAt,
  });
  throw redirect(
    303,
    returnTo.startsWith("/") && !returnTo.startsWith("//")
      ? returnTo
      : "/internal/dashboard",
  );
};

function epochSeconds(value: unknown): number {
  if (typeof value !== "string") throw new Error("session expiry is missing");
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds))
    throw new Error("session expiry is invalid");
  return Math.floor(milliseconds / 1000);
}
