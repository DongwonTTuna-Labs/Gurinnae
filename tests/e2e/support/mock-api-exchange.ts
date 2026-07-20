import {
  asserted,
  body,
  canonicalJsonSha256,
  expiresAt,
  problem,
  runtime,
  sha256,
  token,
} from "./mock-api-state";

export async function handleExchange(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  const exchangeKinds: Record<string, string> = {
    "/v1/submission-session/response:exchange": "RESPONSE_PENDING",
    "/v1/submission-session/response-receipt:exchange": "RESPONSE_RECEIPT",
    "/v1/submission-session/correction-receipt:exchange": "CORRECTION_RECEIPT",
    "/v1/submission-session/subscription-management:exchange":
      "SUBSCRIPTION_MANAGEMENT",
  };
  const exchangeKind = exchangeKinds[url.pathname];
  if (!exchangeKind || request.method !== "POST") return undefined;
  if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
  const input = await body(request);
  const idempotencyKey = request.headers.get("idempotency-key") ?? "";
  if (!idempotencyKey) return problem(400, "IDEMPOTENCY_KEY_REQUIRED");
  const replayKey = `${url.pathname}\0${idempotencyKey}`;
  const bodySha256 = canonicalJsonSha256(input);
  const replay = runtime.exchangeReplays.get(replayKey);
  if (replay) {
    if (replay.bodySha256 !== bodySha256)
      return problem(409, "IDEMPOTENCY_REQUEST_CONFLICT");
    return Response.json(replay.response, {
      headers: { "idempotent-replay": "true" },
    });
  }
  const oneTimeToken =
    typeof input.oneTimeToken === "string" ? input.oneTimeToken : "";
  if (!oneTimeToken) return problem(400, "ONE_TIME_TOKEN_REQUIRED");
  if (oneTimeToken.startsWith("invalid-"))
    return problem(401, "ONE_TIME_TOKEN_INVALID");
  const observation = {
    path: url.pathname,
    tokenSha256: sha256(oneTimeToken),
    sessionKind: exchangeKind,
    idempotencyKeySha256: sha256(idempotencyKey),
  };
  if (runtime.consumedOneTimeTokens.has(oneTimeToken)) {
    runtime.submissionExchanges.push({ ...observation, accepted: false });
    return problem(401, "ONE_TIME_TOKEN_INVALID");
  }
  runtime.consumedOneTimeTokens.add(oneTimeToken);
  const opaqueSessionToken = token(
    `submission-${exchangeKind}-${oneTimeToken}`,
  );
  runtime.submissionExchanges.push({ ...observation, accepted: true });
  const response = {
    status: "exchanged",
    session: {
      opaqueSessionToken,
      sessionKind: exchangeKind,
      scopeId: "77777777-7777-4777-8777-777777777777",
      expiresAt: expiresAt(),
      version: 1,
    },
  };
  runtime.exchangeReplays.set(replayKey, { bodySha256, response });
  return Response.json(response);
}
