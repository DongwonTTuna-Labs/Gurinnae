import { randomUUID } from "node:crypto";
import { invokeControlOperation } from "@gurine/api-client-control";
import { invokeIdentityOperation } from "@gurine/api-client-identity-internal";
import {
  canonicalizeRequestQuery,
  downstreamRequestBinding,
  type IndexedOperation,
  requiredServerValue,
} from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { requestContext } from "./actor-context";
import {
  definedParams,
  isRecord,
  queryRecord,
  sessionToken,
  stringExtension,
  stringValue,
} from "./screen-helpers";
import type { ElevatedAuthorization } from "./screen-types";
import { identityServiceFetch } from "./service-assertion";
export async function controlRequest(
  event: RequestEvent,
  indexed: IndexedOperation,
  path: string,
  rawQuery: string,
  body?: Record<string, unknown>,
  idempotencyKey?: string,
  actionContext?: Record<string, unknown>,
  elevated?: ElevatedAuthorization,
  pathParams: Record<string, string> = definedParams(event.params),
  requiredAssuranceLevel?: "ACTIVE_SESSION" | "STEP_UP",
) {
  const session = sessionToken(event);
  if (!session) throw new Error("SESSION_NOT_ACTIVE");
  const assurance =
    requiredAssuranceLevel ??
    stringExtension(indexed, "x-assurance-level") ??
    "ACTIVE_SESSION";
  const authenticatedFetch: typeof globalThis.fetch = async (
    resource,
    init,
  ) => {
    const original =
      resource instanceof Request ? resource : new Request(resource, init);
    const { request, rawQuery: canonicalRawQuery } =
      canonicalizeRequestQuery(original);
    const url = new URL(request.url);
    // URL construction percent-encodes the literal colon used by addendum
    // command paths (`{id}:decide`, `:claim-review`, ...).  Compare the
    // decoded pathname to the already-bound contract path so this integrity
    // check does not reject a valid generated request before it reaches the
    // downstream API.
    if (decodeURIComponent(url.pathname) !== path)
      throw new Error(
        "generated Control path does not match the bound action path",
      );
    const bodyBytes = new Uint8Array(await request.clone().arrayBuffer());
    const requestIdempotency =
      request.headers.get("idempotency-key") ?? undefined;
    const binding = downstreamRequestBinding({
      method: request.method,
      path: url.pathname,
      ...(canonicalRawQuery ? { rawQuery: canonicalRawQuery } : {}),
      body: bodyBytes,
      contentType: request.headers.get("content-type") ?? "",
      ...(requestIdempotency ? { idempotencyKey: requestIdempotency } : {}),
    });
    const assertion = await identityCall(
      event,
      "/internal/v1/actor-assertions",
      {
        opaqueSessionToken: session,
        downstreamRequest: binding,
        operationId: indexed.operation.operationId,
        requiredCapability: stringExtension(indexed, "x-capability") ?? "",
        actionContext: actionContext ?? null,
        actionDigest: elevated?.actionDigest ?? null,
        stepUpAuthorizationToken: elevated?.stepUpAuthorizationToken ?? null,
        context: requestContext(event),
        requiredAssuranceLevel: assurance,
      },
    );
    if (!assertion.response.ok) return assertion.response;
    const headers = new Headers(request.headers);
    headers.set(
      "x-gurine-actor-assertion",
      stringValue(assertion.value, "actorAssertion"),
    );
    headers.set("x-request-id", randomUUID());
    return event.fetch(new Request(request, { headers }));
  };
  const result = await invokeControlOperation({
    operationId: indexed.operation.operationId,
    baseUrl: requiredServerValue(env, "CONTROL_API_INTERNAL_URL"),
    fetch: authenticatedFetch,
    path: pathParams,
    query: queryRecord(rawQuery),
    ...(body !== undefined ? { body } : {}),
    ...(idempotencyKey
      ? { headers: { "Idempotency-Key": idempotencyKey } }
      : {}),
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  return { response, value };
}

export async function identityCall(
  event: RequestEvent,
  path: string,
  body: Record<string, unknown>,
) {
  const operationId = identityOperations[path];
  if (!operationId)
    throw new Error(`generated identity operation for ${path} is missing`);
  const result = await invokeIdentityOperation({
    operationId,
    baseUrl: requiredServerValue(env, "IDENTITY_API_INTERNAL_URL"),
    fetch: identityServiceFetch(event, env),
    body,
    headers: { "Idempotency-Key": randomUUID() },
  });
  const response = result.response ?? new Response(null, { status: 503 });
  const value = isRecord(result.data)
    ? result.data
    : isRecord(result.error)
      ? result.error
      : {};
  return { response, value };
}

const identityOperations: Readonly<Record<string, string>> = {
  "/internal/v1/oidc/login-transactions": "createLoginTransaction",
  "/internal/v1/oidc/login-callbacks": "consumeLoginCallback",
  "/internal/v1/oidc/step-up-transactions": "createStepUpTransaction",
  "/internal/v1/oidc/step-up-callbacks": "consumeStepUpCallback",
  "/internal/v1/sessions/resolve": "resolveInternalSession",
  "/internal/v1/sessions/revoke": "revokeInternalSession",
  "/internal/v1/security-management-redirect":
    "getSecurityManagementRedirectInternal",
  "/internal/v1/actor-assertions": "issueActorAssertion",
  "/internal/v1/step-up-authorizations/close": "closeStepUpAuthorization",
};
