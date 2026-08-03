import operationSamples from "../../../verification/generated-operation-samples.json";
import {
  asserted,
  attachmentStatus,
  expiresAt,
  problem,
  runtime,
  sha256,
  token,
} from "./mock-api-state";

const responseRequestId = "77777777-7777-4777-8777-777777777777";

function submissionAttachments(
  kind: "correction" | "response",
  sessionToken: string,
) {
  return [...runtime.attachmentUploads.values()]
    .filter(
      (item) =>
        item.kind === kind && item.sessionTokenSha256 === sha256(sessionToken),
    )
    .map(attachmentStatus);
}

function isSubmissionReadPath(pathname: string) {
  return (
    pathname === "/v1/subscription-session" ||
    /^\/v1\/response-(?:receipt|session(?:\/(?:access-status|download|draft|preview))?)$/.test(
      pathname,
    ) ||
    /^\/v1\/correction-(?:receipt|session(?:\/preview)?)$/.test(pathname)
  );
}

export async function handleSubmissionRead(
  request: Request,
  url: URL,
): Promise<Response | undefined> {
  if (request.method !== "GET" || !isSubmissionReadPath(url.pathname))
    return undefined;
  if (!asserted(request)) return problem(401, "SERVICE_ASSERTION_REQUIRED");
  const sessionToken = request.headers.get("x-gurine-submission-session") ?? "";
  if (!sessionToken) return problem(401, "SUBMISSION_SESSION_REQUIRED");
  runtime.submissionReads.push({
    path: url.pathname,
    sessionTokenSha256: sha256(sessionToken),
  });
  const timestamp = new Date().toISOString();
  const expiry = expiresAt();
  const previewConsent = {
    ...operationSamples.getResponseSubmissionPreview.body.publicationConsent,
    body: true,
    redactionAcknowledged: true,
    scopeExplanation: "본문 공개에 동의합니다.",
    updatedAt: timestamp,
  };
  if (url.pathname === "/v1/response-session/access-status") {
    const sample = operationSamples.getResponseAccessStatus.body;
    return Response.json({
      ...sample,
      id: responseRequestId,
      version: 1,
      status: "READY",
      data: {
        ...sample.data,
        status: "VERIFIED",
        expiresAt: expiry,
        remainingAttempts: 3,
        nextAction: "CONTINUE",
      },
    });
  }
  if (url.pathname === "/v1/response-session") {
    const sample = operationSamples.getResponseRequest.body;
    return Response.json({
      ...sample,
      requestId: responseRequestId,
      requestingOrganization: "구린네 검토팀",
      casePublicTitle: "E2E 공개 사건",
      partyName: "E2E 응답 기관",
      dueAt: expiry,
      publicationScope: previewConsent,
      status: "OPEN",
    });
  }
  if (url.pathname === "/v1/response-session/download") {
    const sample = operationSamples.downloadResponseRequest.body;
    return Response.json({
      ...sample,
      binary: btoa(
        JSON.stringify({ requestId: responseRequestId, status: "READY" }),
      ),
    });
  }
  if (url.pathname === "/v1/response-session/draft") {
    const sample = operationSamples.getResponseDraft.body;
    return Response.json({
      ...sample,
      requestId: responseRequestId,
      version: runtime.responseDraftVersion,
      attachments: submissionAttachments("response", sessionToken),
      publicationConsent: {
        ...sample.publicationConsent,
        scopeExplanation: "아직 공개 동의를 확정하지 않았습니다.",
        updatedAt: timestamp,
      },
      savedAt: timestamp,
      expiresAt: expiry,
    });
  }
  if (url.pathname === "/v1/response-session/preview") {
    const sample = operationSamples.getResponseSubmissionPreview.body;
    return Response.json({
      ...sample,
      request: {
        ...sample.request,
        requestId: responseRequestId,
        casePublicTitle: "E2E 공개 사건",
        partyName: "E2E 응답 기관",
        status: "OPEN",
        dueAt: expiry,
        questionCount: 1,
      },
      publicationConsent: previewConsent,
      submissionDigest: "b".repeat(64),
    });
  }
  if (url.pathname === "/v1/response-receipt") {
    const sample = operationSamples.getResponseReceipt.body;
    return Response.json({
      ...sample,
      id: "66666666-6666-4666-8666-666666666666",
      version: 1,
      status: "RECEIVED",
      data: {
        ...sample.data,
        receiptToken: token("response-receipt"),
        requestId: responseRequestId,
        submissionDigest: "b".repeat(64),
        submittedAt: timestamp,
        status: "RECEIVED",
        retentionNotice: "제출 기록은 보존 정책에 따라 관리됩니다.",
      },
    });
  }
  if (url.pathname === "/v1/subscription-session") {
    const sample = operationSamples.getSubscription.body;
    return Response.json({
      ...sample,
      id: "55555555-5555-4555-8555-555555555555",
      version: 1,
      status: "VERIFIED",
      data: {
        ...sample.data,
        managementToken: token("subscription-management"),
        emailMasked: "r***@example.test",
        frequency: "DAILY",
        locale: "ko-KR",
        status: "VERIFIED",
        verifiedAt: timestamp,
      },
    });
  }
  if (url.pathname === "/v1/correction-session") {
    const sample = operationSamples.getCorrectionRequestDraft.body;
    return Response.json({
      ...sample,
      draftToken: token("correction-draft"),
      version: runtime.correctionDraftVersion,
      requestedChanges: ["계약 금액을 원문과 일치시켜 주세요."],
      expiresAt: expiry,
    });
  }
  if (url.pathname === "/v1/correction-session/preview") {
    const sample = operationSamples.getCorrectionRequestDraftPreview.body;
    return Response.json({
      ...sample,
      draft: {
        ...sample.draft,
        draftToken: token("correction-draft"),
        version: runtime.correctionDraftVersion,
        requestedChanges: ["계약 금액을 원문과 일치시켜 주세요."],
        expiresAt: expiry,
      },
      attachments: submissionAttachments("correction", sessionToken),
      submissionDigest: "a".repeat(64),
    });
  }
  if (url.pathname === "/v1/correction-receipt") {
    const sample = operationSamples.getCorrectionReceipt.body;
    return Response.json({
      ...sample,
      id: "99999999-9999-4999-8999-999999999999",
      version: 1,
      status: "RECEIVED",
      data: {
        ...sample.data,
        receiptToken: token("correction-receipt"),
        requestId: "99999999-9999-4999-8999-999999999999",
        submittedAt: timestamp,
        status: "RECEIVED",
        nextUpdateExpectation: "접수 후 검토 결과를 안내합니다.",
      },
    });
  }
  return problem(500, "MOCK_SUBMISSION_READ_UNHANDLED");
}
