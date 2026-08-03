import { redirect } from "@sveltejs/kit";
import { clearAuth, readInternalSession } from "$lib/server/cookies";
import { identityCall, requestContext } from "$lib/server/screen";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async (event) => {
  if (event.request.headers.get("origin") !== event.url.origin)
    throw redirect(303, "/auth/access-denied");
  const session = readInternalSession(event);
  const form = await event.request.formData();
  if (!session || form.get("csrfToken") !== session.csrfToken)
    throw redirect(303, "/auth/access-denied");
  if (session) {
    await identityCall(event, "/internal/v1/sessions/revoke", {
      opaqueSessionToken: session.opaqueIdentitySessionToken,
      reason: "browser logout",
      context: requestContext(event),
    });
  }
  clearAuth(event);
  throw redirect(303, "/auth/sign-in");
};
