import { randomUUID } from "node:crypto";
import {
  abuseProof,
  bffAbuseProof,
  capturedToken,
  clearCapturedMessages,
  deliverNotifications,
  equal,
  hashField,
  invoke,
  scanPending,
  sessionToken,
  sha256,
  upload,
  uuidField,
} from "./submission-flow-support";

export async function runCorrectionFlow(): Promise<void> {
  const contactPath = "/v1/contact-requests";
  const contactBody = {
    category: "GENERAL",
    name: "Submission Integration",
    email: "integration@example.test",
    subject: "Integration boundary",
    message: "Verify encrypted anonymous intake and idempotency.",
    privacyConsent: true,
    abuseProof: bffAbuseProof("createContactRequest"),
  };
  const contactKey = randomUUID();
  const contact = await invoke("POST", contactPath, contactBody, {
    expected: 201,
    idempotencyKey: contactKey,
  });
  const contactReplay = await invoke("POST", contactPath, contactBody, {
    expected: 201,
    idempotencyKey: contactKey,
  });
  equal(
    contactReplay.response.headers.get("idempotent-replay"),
    "true",
    "contact idempotent replay",
  );
  equal(contactReplay.raw, contact.raw, "contact replay body");
  await invoke(
    "POST",
    contactPath,
    {
      ...contactBody,
      email: "unsigned-browser-proof@example.test",
      abuseProof: {
        provider: "SYNTHETIC_TEST",
        token: randomUUID(),
        action: "createContactRequest",
        issuedAt: Math.floor(Date.now() / 1000),
      },
    },
    { expected: 403 },
  );

  const dataset = await invoke(
    "POST",
    "/v1/dataset-exports",
    {
      datasetId: "published-cases",
      format: "JSONL",
      filters: { caseSlugs: ["integration-case"] },
      email: "integration@example.test",
      expiresInSeconds: 3600,
      abuseProof: abuseProof("createDatasetExport"),
    },
    { expected: 202 },
  );
  uuidField(dataset.body, "aggregateId");

  const correctionCreated = await invoke(
    "POST",
    "/v1/correction-session",
    {
      locale: "ko-KR",
      caseSlug: "integration-case",
      publicationRevision: 1,
      abuseProof: abuseProof("createCorrectionRequestDraft"),
    },
    { expected: 201 },
  );
  const correctionSession = sessionToken(correctionCreated.body, "session");
  const correctionDraftId = uuidField(correctionCreated.body, "aggregateId");

  const correctionSaved = await invoke(
    "PUT",
    "/v1/correction-session",
    {
      requesterType: "READER",
      contactEmail: "correction@example.test",
      summary: "The published total needs correction.",
      requestedChanges: ["Replace 10 with 11"],
      evidenceDescription: "Attached source document.",
      expectedVersion: 1,
    },
    { session: correctionSession },
  );
  equal(
    numberField(correctionSaved.body, "resourceVersion"),
    2,
    "correction draft version",
  );
  await invoke("GET", "/v1/correction-session", undefined, {
    session: correctionSession,
  });

  const correctionBytes = Buffer.from("evidence-123");
  const correctionAttachment = await invoke(
    "POST",
    "/v1/correction-session/attachments",
    {
      filename: "evidence.txt",
      mediaType: "text/plain",
      sizeBytes: correctionBytes.length,
      sha256: sha256(correctionBytes),
    },
    { expected: 201, session: correctionSession },
  );
  const correctionAttachmentId = uuidField(
    correctionAttachment.body,
    "aggregateId",
  );
  await upload(
    correctionAttachmentId,
    correctionBytes,
    "public-web",
    correctionSession,
  );
  await invoke(
    "POST",
    `/v1/correction-session/attachments/${correctionAttachmentId}:finalize`,
    {
      objectEtag: "etag-correction",
      uploadedSizeBytes: correctionBytes.length,
      uploadedSha256: sha256(correctionBytes),
    },
    { session: correctionSession },
  );
  scanPending();

  const correctionDeletedAttachment = await invoke(
    "POST",
    "/v1/correction-session/attachments",
    {
      filename: "discard.txt",
      mediaType: "text/plain",
      sizeBytes: 4,
      sha256: "b".repeat(64),
    },
    { expected: 201, session: correctionSession },
  );
  await invoke(
    "DELETE",
    `/v1/correction-session/attachments/${uuidField(correctionDeletedAttachment.body, "aggregateId")}`,
    {},
    { session: correctionSession },
  );
  const correctionPreview = await invoke(
    "GET",
    "/v1/correction-session/preview",
    undefined,
    {
      session: correctionSession,
    },
  );
  hashField(correctionPreview.body, "submissionDigest");

  const correctionSubmitted = await invoke(
    "POST",
    "/v1/correction-session:submit",
    { expectedVersion: 2, attestation: true, privacyConsent: true },
    { expected: 201, session: correctionSession },
  );
  const correctionRequestId = uuidField(
    correctionSubmitted.body,
    "aggregateId",
  );
  equal(correctionRequestId.length > 0, true, "correction request id");
  equal(
    correctionRequestId,
    correctionDraftId,
    "correction canonical id reuse",
  );
  const correctionReceiptSession = sessionToken(
    correctionSubmitted.body,
    "receiptSession",
  );
  await invoke("GET", "/v1/correction-receipt", undefined, {
    session: correctionReceiptSession,
  });
  await invoke("GET", "/v1/correction-session", undefined, {
    session: correctionSession,
    expected: 401,
  });
  await clearCapturedMessages();
  deliverNotifications();
  const correctionReceiptToken = await capturedToken(
    "/correction-request/receipt?token",
  );
  const correctionExchanged = await invoke(
    "POST",
    "/v1/submission-session/correction-receipt:exchange",
    { oneTimeToken: correctionReceiptToken },
  );
  await invoke("GET", "/v1/correction-receipt", undefined, {
    session: sessionToken(correctionExchanged.body, "session"),
  });
  const correctionFailureKey = randomUUID();
  await invoke(
    "POST",
    "/v1/submission-session/correction-receipt:exchange",
    { oneTimeToken: correctionReceiptToken },
    { expected: 401, idempotencyKey: correctionFailureKey },
  );
  await invoke(
    "POST",
    "/v1/submission-session/correction-receipt:exchange",
    { oneTimeToken: correctionReceiptToken },
    { expected: 401, idempotencyKey: correctionFailureKey },
  );

  const disposableCorrection = await invoke(
    "POST",
    "/v1/correction-session",
    { locale: "ko-KR", abuseProof: abuseProof("createCorrectionRequestDraft") },
    { expected: 201 },
  );
  await invoke(
    "DELETE",
    "/v1/correction-session",
    { expectedVersion: 1 },
    {
      expected: 204,
      session: sessionToken(disposableCorrection.body, "session"),
    },
  );
}
