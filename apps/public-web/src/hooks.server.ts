import {
  applyBrowserSecurityHeaders,
  crossOriginProblem,
  isProductionEnvironment,
  unsafeCrossOrigin,
} from "@gurine/config";
import type { Handle } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";

export const handle: Handle = async ({ event, resolve }) => {
  if (unsafeCrossOrigin(event.request, event.url.origin))
    return crossOriginProblem();
  const response = await resolve(event);
  applyBrowserSecurityHeaders(
    response.headers,
    isProductionEnvironment(env.GURINE_ENV),
  );
  return response;
};
