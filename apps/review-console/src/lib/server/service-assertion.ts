import { requiredServerValue, serviceAssertionFetch } from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";

export function identityServiceFetch(
  event: RequestEvent,
  environment: Record<string, string | undefined>,
): typeof globalThis.fetch {
  return serviceAssertionFetch({
    fetch: event.fetch,
    keyBase64: requiredServerValue(
      environment,
      "IDENTITY_SERVICE_HMAC_KEY_CURRENT",
    ),
    issuer: "review-console",
    audience: "identity-api",
  });
}
