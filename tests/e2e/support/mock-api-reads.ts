import {
  asserted,
  attachmentStatus,
  body,
  canonicalJsonSha256,
  expiresAt,
  problem,
  runtime,
  sha256,
  token,
} from "./mock-api-state";

export async function handleReadRoutes(
  request: Request,
  url: URL,
): Promise<Response> {
  const exchangeKinds: Record<string, string> = {
    "/v1/submission-session/response:exchange": "RESPONSE_PENDING",
    "/v1/submission-session/response-receipt:exchange": "RESPONSE_RECEIPT",
    "/v1/submission-session/correction-receipt:exchange": "CORRECTION_RECEIPT",
    "/v1/submission-session/subscription-management:exchange":
      "SUBSCRIPTION_MANAGEMENT",
  };
  const exchangeKind = exchangeKinds[url.pathname];
  if (exchangeKind && request.method === "POST") {
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

  const submissionReadPaths = new Set([
    "/v1/response-session/access-status",
    "/v1/response-session",
    "/v1/response-session/draft",
    "/v1/response-session/download",
    "/v1/response-session/preview",
    "/v1/response-receipt",
    "/v1/correction-session",
    "/v1/correction-session/preview",
    "/v1/correction-receipt",
    "/v1/subscription-session",
  ]);
  if (request.method === "GET" && submissionReadPaths.has(url.pathname)) {
    if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
    const sessionToken =
      request.headers.get("x-gurine-submission-session") ?? "";
    if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
    runtime.submissionReads.push({
      path: url.pathname,
      sessionTokenSha256: sha256(sessionToken),
    });
    if (url.pathname === "/v1/response-session/download") {
      return Response.json({
        binary: btoa(
          JSON.stringify({
            requestId: "77777777-7777-4777-8777-777777777777",
            status: "READY",
          }),
        ),
      });
    }
    if (url.pathname === "/v1/response-session/draft") {
      const attachments = [...runtime.attachmentUploads.values()]
        .filter(
          (item) =>
            item.kind === "response" &&
            item.sessionTokenSha256 === sha256(sessionToken),
        )
        .map(attachmentStatus);
      return Response.json({
        requestId: "77777777-7777-4777-8777-777777777777",
        version: runtime.responseDraftVersion,
        answers: [],
        attachments,
        publicationConsent: {
          body: false,
          attachments: [],
          redactionAcknowledged: false,
          scopeExplanation: "아직 공개 동의를 확정하지 않았습니다.",
          updatedAt: new Date().toISOString(),
        },
        savedAt: new Date().toISOString(),
        expiresAt: expiresAt(),
      });
    }
    if (url.pathname === "/v1/response-session/preview") {
      return Response.json({
        request: {
          requestId: "77777777-7777-4777-8777-777777777777",
          casePublicTitle: "E2E 공개 사건",
          partyName: "E2E 응답 기관",
          status: "OPEN",
          dueAt: expiresAt(),
          questionCount: 1,
        },
        answers: [],
        attachments: [],
        publicationConsent: {
          body: true,
          attachments: [],
          redactionAcknowledged: true,
          scopeExplanation: "본문 공개에 동의합니다.",
          updatedAt: new Date().toISOString(),
        },
        warnings: [],
        submissionDigest: "b".repeat(64),
      });
    }
    if (url.pathname === "/v1/correction-session") {
      return Response.json({
        id: "88888888-8888-4888-8888-888888888888",
        version: runtime.correctionDraftVersion,
        requesterType: "CITIZEN",
        contactEmail: "requester@example.test",
        summary: "공개 문장의 수치를 바로잡아 주세요.",
        requestedChanges: ["계약 금액을 원문과 일치시켜 주세요."],
        evidenceDescription: "공개 원문 링크를 확인했습니다.",
      });
    }
    if (url.pathname === "/v1/correction-session/preview") {
      const attachments = [...runtime.attachmentUploads.values()]
        .filter(
          (item) =>
            item.kind === "correction" &&
            item.sessionTokenSha256 === sha256(sessionToken),
        )
        .map(attachmentStatus);
      return Response.json({
        draft: {
          id: "88888888-8888-4888-8888-888888888888",
          version: runtime.correctionDraftVersion,
        },
        attachments,
        warnings: [],
        submissionDigest: "a".repeat(64),
      });
    }
    return Response.json({
      id: "77777777-7777-4777-8777-777777777777",
      status: "READY",
      version: 1,
      items: [],
      links: [],
    });
  }

  if (request.method === "GET") {
    if (url.pathname === "/v1/internal/queries/get-publish-confirmation") {
      return Response.json({
        id: "00000000-0000-4000-8000-000000000020",
        status: "ready",
        data: {
          caseId: "00000000-0000-4000-8000-000000000010",
          snapshotId: "00000000-0000-4000-8000-000000000020",
          previewHash: "b".repeat(64),
          currentCaseVersion: 1,
          requiredReauth: true,
          impactSummary: ["공개 projection과 알림이 갱신됩니다."],
          publicUrls: ["/cases/e2e-case"],
        },
        links: [],
      });
    }
    return Response.json({
      items: [],
      appliedFilters: Object.fromEntries(url.searchParams),
      asOf: "2026-07-12T00:00:00Z",
      nextCursor: null,
    });
  }
  return problem(409, "SYNTHETIC_READ_ONLY", "Synthetic mutation disabled");
}
