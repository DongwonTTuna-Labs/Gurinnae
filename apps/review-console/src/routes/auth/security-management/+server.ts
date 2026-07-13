import { redirect } from "@sveltejs/kit";
import { readInternalSession } from "$lib/server/cookies";
import { identityCall, requestContext } from "$lib/server/screen";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async (event) => {
  const session = readInternalSession(event);
  if (!session) throw redirect(303, "/auth/login");
  const result = await identityCall(
    event,
    "/internal/v1/security-management-redirect",
    {
      opaqueSessionToken: session.opaqueIdentitySessionToken,
      returnTo: "/internal/account",
      context: requestContext(event),
    },
  );
  const target = result.value.redirectUrl;
  if (!result.response.ok || typeof target !== "string")
    throw redirect(303, "/auth/access-denied");
  throw redirect(303, target);
};
