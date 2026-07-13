import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomUUID } from "node:crypto";

const base = required("SUBMISSION_TEST_BASE_URL");
const container = required("SUBMISSION_TEST_DB_CONTAINER");
const database = required("SUBMISSION_TEST_DATABASE");
const serviceKey = Buffer.from(
  required("SUBMISSION_SERVICE_HMAC_KEY"),
  "base64",
);
const botSecret = required("SUBMISSION_BOT_CHALLENGE_SECRET");
const fieldKey = Buffer.from(required("SUBMISSION_FIELD_KEY"), "base64");
const smtpCaptureUrl = required("SMTP_CAPTURE_HTTP_URL");
const magicToken = required("SUBMISSION_RESPONSE_MAGIC_TOKEN");
const responseOtp = required("SUBMISSION_RESPONSE_OTP");

const sha256 = (value: string | Buffer): string =>
  createHash("sha256").update(value).digest("hex");

const derivedToken = (purpose: string, id: string): string =>
  createHmac("sha256", serviceKey)
    .update(purpose)
    .update(":")
    .update(Buffer.from(id.replaceAll("-", ""), "hex"))
    .digest("base64url");

const responseRequestId = "33333333-3333-4333-8333-333333333333";
const responseEmailEnvelope = encryptField(
  "editorial.response_requests",
  "recipient_email_encrypted",
  responseRequestId,
  "email-address",
  "respondent@example.test",
);
admin(
  `UPDATE editorial.response_requests SET recipient_email_encrypted=convert_to('${responseEmailEnvelope}','UTF8') WHERE id='${responseRequestId}'`,
);

function serviceAssertion(
  issuer: "public-web" | "response-portal",
  method: string,
  path: string,
  body: string | Buffer,
  contentType = typeof body === "string" && body === ""
    ? ""
    : "application/json",
): string {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    aud: "submission-api",
    bodySha256: sha256(body),
    contentType,
    exp: now + 30,
    iat: now,
    iss: issuer,
    jti: randomUUID(),
    method,
    path,
    querySha256: sha256(""),
    typ: "service",
    v: 1,
  };
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const signingInput = `gurine-sa-v1.${sha256(serviceKey).slice(0, 16)}.${payload}`;
  const signature = createHmac("sha256", serviceKey)
    .update(signingInput)
    .digest("base64url");
  return `${signingInput}.${signature}`;
}

async function upload(
  attachmentId: string,
  bytes: Buffer,
  issuer: "public-web" | "response-portal",
  session: string,
): Promise<void> {
  const path = `/internal/submission-uploads/${attachmentId}`;
  const response = await fetch(`${base}${path}`, {
    method: "PUT",
    headers: {
      "content-type": "application/octet-stream",
      "x-gurine-service-assertion": serviceAssertion(
        issuer,
        "PUT",
        path,
        bytes,
        "application/octet-stream",
      ),
      "x-gurine-submission-session": session,
      "x-request-id": randomUUID(),
    },
    body: bytes,
  });
  const text = await response.text();
  if (response.status !== 204) {
    throw new Error(
      `PUT ${path}: expected 204, got ${response.status}: ${text}`,
    );
  }
}

type CallOptions = {
  issuer?: "public-web" | "response-portal";
  session?: string;
  expected?: number;
  idempotencyKey?: string;
  assertion?: string;
};

type Invocation = {
  body: Record<string, unknown>;
  response: Response;
  raw: string;
};

async function invoke(
  method: string,
  path: string,
  value: Record<string, unknown> | undefined,
  options: CallOptions = {},
): Promise<Invocation> {
  const body = value === undefined ? "" : JSON.stringify(value);
  const issuer = options.issuer ?? "public-web";
  const headers: Record<string, string> = {
    "idempotency-key": options.idempotencyKey ?? randomUUID(),
    "x-gurine-service-assertion":
      options.assertion ?? serviceAssertion(issuer, method, path, body),
    "x-request-id": randomUUID(),
  };
  if (body !== "") headers["content-type"] = "application/json";
  if (options.session !== undefined) {
    headers["x-gurine-submission-session"] = options.session;
  }
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === "" ? undefined : body,
  });
  const raw = await response.text();
  const parsed = raw === "" ? {} : parseRecord(raw);
  const expected = options.expected ?? 200;
  if (response.status !== expected) {
    throw new Error(
      `${method} ${path}: expected ${expected}, got ${response.status}: ${raw}`,
    );
  }
  return { body: parsed, response, raw };
}

function abuseProof(action: string): Record<string, unknown> {
  const issuedAt = Math.floor(Date.now() / 1000);
  return {
    provider: "SYNTHETIC_TEST",
    token: createHmac("sha256", botSecret)
      .update(`${action}:${issuedAt}`)
      .digest("hex"),
    action,
    issuedAt,
  };
}

function admin(sql: string): string {
  return execFileSync(
    "docker",
    [
      "exec",
      container,
      "psql",
      "-At",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      database,
      "-c",
      sql,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();
}

function scanPending(): void {
  dispatchEvents();
  execFileSync("target/debug/gurine-workflow-worker", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function deliverNotifications(): void {
  dispatchEvents();
  execFileSync("target/debug/gurine-notification-worker", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function dispatchEvents(): void {
  execFileSync("target/debug/gurine-scheduler", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

async function capturedToken(path: string): Promise<string> {
  const response = await fetch(smtpCaptureUrl);
  const value: unknown = await response.json();
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("SMTP capture response is invalid");
  }
  const messages = (value as { messages?: unknown }).messages;
  if (
    !Array.isArray(messages) ||
    messages.some((message) => typeof message !== "string")
  ) {
    throw new Error("SMTP capture messages are invalid");
  }
  const message = [...(messages as string[])]
    .reverse()
    .find((item) => item.includes(path));
  if (message === undefined)
    throw new Error(`SMTP message for ${path} is missing`);
  // lettre emits quoted-printable bodies and is allowed to insert RFC 2045
  // soft line breaks in the middle of long receipt URLs.  Match against the
  // unfolded transfer representation so the assertion still validates the
  // exact 256-bit URL-safe token rather than depending on encoder wrapping.
  const decoded = message.replaceAll("=\r\n", "").replace(/=3D/gi, "=");
  const escapedPath = path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = decoded.match(new RegExp(`${escapedPath}=([A-Za-z0-9_-]{43})`));
  if (match?.[1] === undefined)
    throw new Error(`SMTP token for ${path} is missing`);
  return match[1];
}

async function clearCapturedMessages(): Promise<void> {
  const response = await fetch(smtpCaptureUrl, { method: "DELETE" });
  if (response.status !== 204) {
    throw new Error(`SMTP capture clear failed: ${response.status}`);
  }
}

const contactPath = "/v1/contact-requests";
const contactBody = {
  category: "GENERAL",
  name: "Submission Integration",
  email: "integration@example.test",
  subject: "Integration boundary",
  message: "Verify encrypted anonymous intake and idempotency.",
  privacyConsent: true,
  abuseProof: abuseProof("createContactRequest"),
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
const correctionRequestId = uuidField(correctionSubmitted.body, "aggregateId");
equal(correctionRequestId.length > 0, true, "correction request id");
equal(correctionRequestId, correctionDraftId, "correction canonical id reuse");
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
await invoke(
  "POST",
  "/v1/submission-session/correction-receipt:exchange",
  { oneTimeToken: correctionReceiptToken },
  { expected: 401 },
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

const responseRequest = await invoke("GET", "/v1/response-session", undefined, {
  issuer: "response-portal",
  session: activeResponseSession,
});
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
  { issuer: "response-portal", expected: 201, session: activeResponseSession },
);
const responseAttachmentId = uuidField(responseAttachment.body, "aggregateId");
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
  { issuer: "response-portal", expected: 201, session: activeResponseSession },
);
const infectedAttachmentId = uuidField(infectedAttachment.body, "aggregateId");
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
  { issuer: "response-portal", expected: 204, session: activeResponseSession },
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
  { issuer: "response-portal", expected: 201, session: activeResponseSession },
);
await invoke(
  "DELETE",
  `/v1/response-session/attachments/${uuidField(responseDiscard.body, "aggregateId")}`,
  {},
  { issuer: "response-portal", expected: 204, session: activeResponseSession },
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
  { issuer: "response-portal", expected: 202, session: activeResponseSession },
);
const responseSubmitted = await invoke(
  "POST",
  "/v1/response-session:submit",
  { expectedVersion: 1, attestation: true, publicationConsent: consent },
  { issuer: "response-portal", expected: 201, session: activeResponseSession },
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
uuidField(subscriptionCreated.body, "aggregateId");
await clearCapturedMessages();
deliverNotifications();
const verificationToken = await capturedToken("/subscription/verify?token");
const managementToken = await capturedToken("/subscription/manage?token");
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

console.log(
  "submission 34-operation/session/encryption/object-bytes/ClamAV integration: PASS",
);

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") throw new Error(`missing ${name}`);
  return value;
}

function parseRecord(value: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(value);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("expected JSON object");
  }
  return parsed as Record<string, unknown>;
}

function recordField(
  value: Record<string, unknown>,
  name: string,
): Record<string, unknown> {
  const field = value[name];
  if (typeof field !== "object" || field === null || Array.isArray(field)) {
    throw new Error(`${name} is not an object`);
  }
  return field as Record<string, unknown>;
}

function arrayField(
  value: Record<string, unknown>,
  name: string,
): Record<string, unknown>[] {
  const field = value[name];
  if (
    !Array.isArray(field) ||
    field.some(
      (item) =>
        typeof item !== "object" || item === null || Array.isArray(item),
    )
  ) {
    throw new Error(`${name} is not an object array`);
  }
  return field as Record<string, unknown>[];
}

function stringField(value: Record<string, unknown>, name: string): string {
  const field = value[name];
  if (typeof field !== "string" || field === "")
    throw new Error(`${name} is not a string`);
  return field;
}

function numberField(value: Record<string, unknown>, name: string): number {
  const field = value[name];
  if (typeof field !== "number") throw new Error(`${name} is not a number`);
  return field;
}

function uuidField(value: Record<string, unknown>, name: string): string {
  const field = stringField(value, name);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      field,
    )
  ) {
    throw new Error(`${name} is not a UUIDv4`);
  }
  return field;
}

function hashField(value: Record<string, unknown>, name: string): string {
  const field = stringField(value, name);
  if (!/^[a-f0-9]{64}$/.test(field))
    throw new Error(`${name} is not a sha256 digest`);
  return field;
}

function sessionToken(value: Record<string, unknown>, name: string): string {
  const session = recordField(value, name);
  const token = stringField(session, "opaqueSessionToken");
  if (!/^[A-Za-z0-9_-]{43}$/.test(token))
    throw new Error(`${name} token is not 256-bit base64url`);
  return token;
}

function equal(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${String(expected)}, got ${String(actual)}`,
    );
  }
}

function encryptField(
  table: string,
  column: string,
  id: string,
  logicalType: string,
  plaintext: string,
): string {
  if (fieldKey.length !== 32) throw new Error("field key must be 32 bytes");
  return execFileSync("target/debug/field-envelope", [], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: {
      ...process.env,
      FIELD_KEY_BASE64: fieldKey.toString("base64"),
      FIELD_TABLE: table,
      FIELD_COLUMN: column,
      FIELD_RECORD_ID: id,
      FIELD_LOGICAL_TYPE: logicalType,
      FIELD_PLAINTEXT: plaintext,
    },
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}
