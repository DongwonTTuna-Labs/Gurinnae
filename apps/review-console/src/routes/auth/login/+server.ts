import { redirect } from "@sveltejs/kit";
import { setLoginTransaction } from "$lib/server/cookies";
import { identityCall, requestContext } from "$lib/server/screen";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async (event) => {
  const requested =
    event.url.searchParams.get("returnTo") ?? "/internal/dashboard";
  const returnTo =
    requested.startsWith("/") && !requested.startsWith("//")
      ? requested
      : "/internal/dashboard";
  const result = await identityCall(
    event,
    "/internal/v1/oidc/login-transactions",
    {
      returnTo,
      callbackUri: new URL("/auth/callback", event.url).toString(),
      context: requestContext(event),
    },
  );
  if (!result.response.ok) throw redirect(303, "/auth/access-denied");
  const transaction = result.value.transactionCookieValue;
  const authorizationUrl = result.value.authorizationUrl;
  if (typeof transaction !== "string" || typeof authorizationUrl !== "string") {
    throw redirect(303, "/auth/access-denied");
  }
  setLoginTransaction(event, transaction);
  throw redirect(303, authorizationUrl);
};
