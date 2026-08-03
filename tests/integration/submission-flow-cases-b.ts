import { createHmac } from "node:crypto";
import {
  abuseProof,
  admin,
  arrayField,
  capturedToken,
  clearCapturedMessages,
  deliverNotifications,
  derivedToken,
  equal,
  hashField,
  invoke,
  magicToken,
  numberField,
  responseOtp,
  scanPending,
  serviceAssertion,
  serviceKey,
  sessionToken,
  sha256,
  stringField,
  upload,
  uuidField,
} from "./submission-flow-support";

export async function runResponseFlow(): Promise<void> {
  const responseExchange = await invoke(
    "POST",
    "/v1/submission-session/response:exchange",
    { oneTimeToken: magicToken },
    { issuer: "response-portal" },
  );
  const pendingResponseSession = sessionToken(responseExchange.body, "session");
  await invoke("GET", "/v1/response-session/access-status", undefined, {
    issuer: "response-portal",
    session: pendingResponseSession,
  });
  await invoke("GET", "/v1/response-session/access-status", undefined, {
    issuer: "public-web",
    session: pendingResponseSession,
    expected: 403,
  });
  await invoke(
    "POST",
    "/v1/response-session:verify",
    { emailOtp: "000000" },
    { issuer: "response-portal", session: pendingResponseSession },
  );
  const responseVerified = await invoke(
    "POST",
    "/v1/response-session:verify",
    { emailOtp: responseOtp },
    { issuer: "response-portal", session: pendingResponseSession },
  );
  const activeResponseSession = sessionToken(responseVerified.body, "session");
  await invoke(
    "POST",
    "/v1/response-session:verify",
    { emailOtp: responseOtp },
    {
      issuer: "response-portal",
      session: pendingResponseSession,
      expected: 401,
    },
  );

  const responseRequest = await invoke(
    "GET",
    "/v1/response-session",
    undefined,
    {
      issuer: "response-portal",
      session: activeResponseSession,
    },
  );
  uuidField(responseRequest.body, "requestId");
  await invoke("GET", "/v1/response-session/download", undefined, {
    issuer: "response-portal",
    session: activeResponseSession,
  });
  const emptyDraft = await invoke(
    "GET",
    "/v1/response-session/draft",
    undefined,
    {
      issuer: "response-portal",
      session: activeResponseSession,
    },
  );
  equal(
    numberField(emptyDraft.body, "version"),
    0,
    "initial response draft version",
  );

  const consent = {
    bodyConsent: true,
    attachmentConsents: [],
    identityDisplay: "ROLE_ONLY",
    redactionAcknowledged: true,
    excerptReviewRequested: false,
    consentedAt: new Date().toISOString(),
  };
  const answers = [
    {
      questionId: "q1",
      text: "The corrected response is attached.",
      attachmentIds: [],
      updatedAt: new Date().toISOString(),
    },
  ];
  const savedResponse = await invoke(
    "PUT",
    "/v1/response-session/draft",
    { answers, publicationConsent: consent, expectedVersion: 0 },
    { issuer: "response-portal", session: activeResponseSession },
  );
  equal(
    numberField(savedResponse.body, "aggregateVersion"),
    1,
    "saved response version",
  );

  const responseBytes = Buffer.from("response-pdf-001");
  const responseAttachment = await invoke(
    "POST",
    "/v1/response-session/attachments",
    {
      filename: "response.pdf",
      mediaType: "application/pdf",
      sizeBytes: responseBytes.length,
      sha256: sha256(responseBytes),
    },
    {
      issuer: "response-portal",
      expected: 201,
      session: activeResponseSession,
    },
  );
  const responseAttachmentId = uuidField(
    responseAttachment.body,
    "aggregateId",
  );
  await upload(
    responseAttachmentId,
    responseBytes,
    "response-portal",
    activeResponseSession,
  );
  await invoke(
    "POST",
    `/v1/response-session/attachments/${responseAttachmentId}:finalize`,
    {
      objectEtag: "etag-response",
      uploadedSizeBytes: responseBytes.length,
      uploadedSha256: sha256(responseBytes),
    },
    { issuer: "response-portal", session: activeResponseSession },
  );
  const eicar = Buffer.from(
    "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*",
  );
  const infectedAttachment = await invoke(
    "POST",
    "/v1/response-session/attachments",
    {
      filename: "eicar.txt",
      mediaType: "text/plain",
      sizeBytes: eicar.length,
      sha256: sha256(eicar),
    },
    {
      issuer: "response-portal",
      expected: 201,
      session: activeResponseSession,
    },
  );
  const infectedAttachmentId = uuidField(
    infectedAttachment.body,
    "aggregateId",
  );
  await upload(
    infectedAttachmentId,
    eicar,
    "response-portal",
    activeResponseSession,
  );
  await invoke(
    "POST",
    `/v1/response-session/attachments/${infectedAttachmentId}:finalize`,
    {
      objectEtag: "etag-infected",
      uploadedSizeBytes: eicar.length,
      uploadedSha256: sha256(eicar),
    },
    { issuer: "response-portal", session: activeResponseSession },
  );
  scanPending();
  const scannedDraft = await invoke(
    "GET",
    "/v1/response-session/draft",
    undefined,
    {
      issuer: "response-portal",
      session: activeResponseSession,
    },
  );
  const scannedAttachments = arrayField(scannedDraft.body, "attachments");
  const infectedProjection = scannedAttachments.find(
    (item) => stringField(item, "id") === infectedAttachmentId,
  );
  if (infectedProjection === undefined)
    throw new Error("infected attachment projection is missing");
  equal(
    stringField(infectedProjection, "scanStatus"),
    "INFECTED",
    "ClamAV EICAR detection",
  );
  await invoke(
    "DELETE",
    `/v1/response-session/attachments/${infectedAttachmentId}`,
    {},
    {
      issuer: "response-portal",
      expected: 204,
      session: activeResponseSession,
    },
  );
  const responseDiscard = await invoke(
    "POST",
    "/v1/response-session/attachments",
    {
      filename: "discard.txt",
      mediaType: "text/plain",
      sizeBytes: 8,
      sha256: "d".repeat(64),
    },
    {
      issuer: "response-portal",
      expected: 201,
      session: activeResponseSession,
    },
  );
  await invoke(
    "DELETE",
    `/v1/response-session/attachments/${uuidField(responseDiscard.body, "aggregateId")}`,
    {},
    {
      issuer: "response-portal",
      expected: 204,
      session: activeResponseSession,
    },
  );
  await invoke("GET", "/v1/response-session/draft", undefined, {
    issuer: "response-portal",
    session: activeResponseSession,
  });
  const responsePreview = await invoke(
    "GET",
    "/v1/response-session/preview",
    undefined,
    {
      issuer: "response-portal",
      session: activeResponseSession,
    },
  );
  hashField(responsePreview.body, "submissionDigest");
  await invoke(
    "POST",
    "/v1/response-session:request-extension",
    {
      requestedDueAt: new Date(Date.now() + 3 * 86_400_000).toISOString(),
      reason: "Additional evidence review",
    },
    {
      issuer: "response-portal",
      expected: 202,
      session: activeResponseSession,
    },
  );
  const responseSubmitted = await invoke(
    "POST",
    "/v1/response-session:submit",
    { expectedVersion: 1, attestation: true, publicationConsent: consent },
    {
      issuer: "response-portal",
      expected: 201,
      session: activeResponseSession,
    },
  );
  const responseSubmissionId = uuidField(responseSubmitted.body, "aggregateId");
  const responseReceiptSession = sessionToken(
    responseSubmitted.body,
    "receiptSession",
  );
  await invoke("GET", "/v1/response-receipt", undefined, {
    issuer: "response-portal",
    session: responseReceiptSession,
  });
  await invoke("GET", "/v1/response-session/draft", undefined, {
    issuer: "response-portal",
    session: activeResponseSession,
    expected: 401,
  });
  await clearCapturedMessages();
  deliverNotifications();
  const responseReceiptToken = await capturedToken("/respond/receipt?token");
  const expectedResponseReceiptHash = createHmac("sha256", serviceKey)
    .update(derivedToken("response-receipt", responseSubmissionId))
    .digest("hex");
  const storedResponseReceiptHash = admin(
    `SELECT btrim(receipt_token_hash::text) FROM intake.response_submissions WHERE id='${responseSubmissionId}'`,
  );
  equal(
    storedResponseReceiptHash,
    expectedResponseReceiptHash,
    `stored response receipt token ${responseSubmissionId}`,
  );
  equal(
    createHmac("sha256", serviceKey).update(responseReceiptToken).digest("hex"),
    storedResponseReceiptHash,
    "response receipt token hash",
  );
  const responseReceiptExchange = await invoke(
    "POST",
    "/v1/submission-session/response-receipt:exchange",
    { oneTimeToken: responseReceiptToken },
    { issuer: "response-portal" },
  );
  await invoke("GET", "/v1/response-receipt", undefined, {
    issuer: "response-portal",
    session: sessionToken(responseReceiptExchange.body, "session"),
  });
  await invoke(
    "POST",
    "/v1/submission-session/response-receipt:exchange",
    { oneTimeToken: responseReceiptToken },
    { issuer: "response-portal", expected: 401 },
  );

  const subscriptionCreated = await invoke(
    "POST",
    "/v1/subscription-session",
    {
      email: "subscriber@example.test",
      scopeType: "CASE",
      scopeRef: "integration-case",
      frequency: "DAILY",
      locale: "ko-KR",
      consent: true,
      abuseProof: abuseProof("createSubscription"),
    },
    { expected: 201 },
  );
  const subscriptionId = uuidField(subscriptionCreated.body, "aggregateId");
  equal(
    subscriptionCreated.body.verificationDispatched,
    true,
    "persisted subscription verification dispatch receipt",
  );
  equal(
    admin(
      `SELECT count(*) FROM intake.subscriptions WHERE id='${subscriptionId}' AND status='PENDING'`,
    ),
    "1",
    "persisted pending subscription",
  );
  equal(
    admin(
      `SELECT count(*) FROM ops.outbox WHERE aggregate_type='subscription' AND aggregate_id='${subscriptionId}' AND event_type='notification.subscription_verification_requested.v1'`,
    ),
    "1",
    "persisted subscription verification outbox receipt",
  );
  await clearCapturedMessages();
  deliverNotifications();
  const verificationToken = await capturedToken("/subscribe?token");
  const managementToken = await capturedToken(
    "/subscription/manage/exchange?token",
  );
  const subscriptionVerified = await invoke(
    "POST",
    "/v1/submission-session/subscription:verify",
    { verificationToken },
  );
  const managementSession = sessionToken(subscriptionVerified.body, "session");
  await invoke("GET", "/v1/subscription-session", undefined, {
    session: managementSession,
  });
  await invoke(
    "PATCH",
    "/v1/subscription-session",
    { frequency: "WEEKLY", paused: true, scope: { scopeType: "CORRECTIONS" } },
    { session: managementSession },
  );
  const managementExchange = await invoke(
    "POST",
    "/v1/submission-session/subscription-management:exchange",
    { oneTimeToken: managementToken },
  );
  const exchangedManagementSession = sessionToken(
    managementExchange.body,
    "session",
  );
  await invoke("GET", "/v1/subscription-session", undefined, {
    session: exchangedManagementSession,
  });
  await invoke(
    "POST",
    "/v1/submission-session/subscription-management:exchange",
    { oneTimeToken: managementToken },
    { expected: 401 },
  );
  await invoke(
    "POST",
    "/v1/subscription-session:unsubscribe",
    {},
    { session: managementSession },
  );
  await invoke("GET", "/v1/subscription-session", undefined, {
    session: managementSession,
    expected: 401,
  });
  await invoke("GET", "/v1/subscription-session", undefined, {
    session: exchangedManagementSession,
    expected: 401,
  });

  const assertionBody = JSON.stringify({ oneTimeToken: magicToken });
  const replayAssertion = serviceAssertion(
    "response-portal",
    "POST",
    "/v1/submission-session/response:exchange",
    assertionBody,
  );
  await invoke(
    "POST",
    "/v1/submission-session/response:exchange",
    { oneTimeToken: magicToken },
    { issuer: "response-portal", assertion: replayAssertion, expected: 401 },
  );
  await invoke(
    "POST",
    "/v1/submission-session/response:exchange",
    { oneTimeToken: magicToken },
    { issuer: "response-portal", assertion: replayAssertion, expected: 409 },
  );
}
