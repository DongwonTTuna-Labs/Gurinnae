import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomUUID } from "node:crypto";

export const base = required("SUBMISSION_TEST_BASE_URL");
export const container = required("SUBMISSION_TEST_DB_CONTAINER");
export const database = required("SUBMISSION_TEST_DATABASE");
export const serviceKey = Buffer.from(
  required("SUBMISSION_SERVICE_HMAC_KEY"),
  "base64",
);
export const botSecret = required("SUBMISSION_BOT_CHALLENGE_SECRET");
export const fieldKey = Buffer.from(required("SUBMISSION_FIELD_KEY"), "base64");
export const smtpCaptureUrl = required("SMTP_CAPTURE_HTTP_URL");
export const magicToken = required("SUBMISSION_RESPONSE_MAGIC_TOKEN");
export const responseOtp = required("SUBMISSION_RESPONSE_OTP");

export const sha256 = (value: string | Buffer): string =>
  createHash("sha256").update(value).digest("hex");

export const derivedToken = (purpose: string, id: string): string =>
  createHmac("sha256", serviceKey)
    .update(purpose)
    .update(":")
    .update(Buffer.from(id.replaceAll("-", ""), "hex"))
    .digest("base64url");

export const responseRequestId = "33333333-3333-4333-8333-333333333333";
export const responseEmailEnvelope = encryptField(
  "editorial.response_requests",
  "recipient_email_encrypted",
  responseRequestId,
  "email-address",
  "respondent@example.test",
);
admin(
  `UPDATE editorial.response_requests SET recipient_email_encrypted=convert_to('${responseEmailEnvelope}','UTF8') WHERE id='${responseRequestId}'`,
);

export function serviceAssertion(
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

export async function upload(
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

export async function invoke(
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

export function abuseProof(action: string): Record<string, unknown> {
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

export function bffAbuseProof(action: string): Record<string, unknown> {
  const issuedAt = Math.floor(Date.now() / 1000);
  const nonce = randomUUID();
  const kid = sha256(serviceKey).slice(0, 16);
  const signature = createHmac("sha256", serviceKey)
    .update(
      ["gurine-synthetic-proof-v1", action, String(issuedAt), nonce].join("\0"),
    )
    .digest("hex");
  return {
    provider: "SYNTHETIC_TEST",
    token: `gurine-synth-v1.${kid}.${nonce}.${signature}`,
    action,
    issuedAt,
  };
}

export function admin(sql: string): string {
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

export function scanPending(): void {
  dispatchEvents();
  execFileSync("target/debug/gurine-workflow-worker", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function deliverNotifications(): void {
  dispatchEvents();
  execFileSync("target/debug/gurine-notification-worker", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function dispatchEvents(): void {
  execFileSync("target/debug/gurine-scheduler", [], {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export async function capturedToken(path: string): Promise<string> {
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

export async function clearCapturedMessages(): Promise<void> {
  const response = await fetch(smtpCaptureUrl, { method: "DELETE" });
  if (response.status !== 204) {
    throw new Error(`SMTP capture clear failed: ${response.status}`);
  }
}

export function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") throw new Error(`missing ${name}`);
  return value;
}

export function parseRecord(value: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(value);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("expected JSON object");
  }
  return parsed as Record<string, unknown>;
}

export function recordField(
  value: Record<string, unknown>,
  name: string,
): Record<string, unknown> {
  const field = value[name];
  if (typeof field !== "object" || field === null || Array.isArray(field)) {
    throw new Error(`${name} is not an object`);
  }
  return field as Record<string, unknown>;
}

export function arrayField(
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

export function stringField(
  value: Record<string, unknown>,
  name: string,
): string {
  const field = value[name];
  if (typeof field !== "string" || field === "")
    throw new Error(`${name} is not a string`);
  return field;
}

export function numberField(
  value: Record<string, unknown>,
  name: string,
): number {
  const field = value[name];
  if (typeof field !== "number") throw new Error(`${name} is not a number`);
  return field;
}

export function uuidField(
  value: Record<string, unknown>,
  name: string,
): string {
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

export function hashField(
  value: Record<string, unknown>,
  name: string,
): string {
  const field = stringField(value, name);
  if (!/^[a-f0-9]{64}$/.test(field))
    throw new Error(`${name} is not a sha256 digest`);
  return field;
}

export function sessionToken(
  value: Record<string, unknown>,
  name: string,
): string {
  const session = recordField(value, name);
  const token = stringField(session, "opaqueSessionToken");
  if (!/^[A-Za-z0-9_-]{43}$/.test(token))
    throw new Error(`${name} token is not 256-bit base64url`);
  return token;
}

export function equal(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${String(expected)}, got ${String(actual)}`,
    );
  }
}

export function encryptField(
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
