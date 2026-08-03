import { createHash, createHmac, randomUUID } from "node:crypto";

const digest = (value: string | Uint8Array): string =>
  createHash("sha256").update(value).digest("hex");

const NEXT_SUBMISSION_SESSION_HEADER =
  "x-gurine-next-submission-session" as const;
const SUBMISSION_SESSION_TOKEN = /^[A-Za-z0-9_-]{43}$/;

export function downstreamRequestBinding(input: {
  method: string;
  path: string;
  rawQuery?: string;
  body: string | Uint8Array;
  contentType: string;
  idempotencyKey?: string;
}) {
  const querySha256 = digest(canonicalQuery(input.rawQuery ?? ""));
  const bodySha256 = digest(input.body);
  const contentType = input.body.length === 0 ? "" : input.contentType;
  const idempotencyKeySha256 = input.idempotencyKey
    ? digest(input.idempotencyKey)
    : undefined;
  const requestDigest = digest(
    `${input.method}\n${input.path}\n${querySha256}\n${bodySha256}\n${contentType}\n${idempotencyKeySha256 ?? ""}`,
  );
  return {
    method: input.method,
    normalizedPath: input.path,
    querySha256,
    bodySha256,
    contentType,
    requestDigest,
    ...(idempotencyKeySha256 ? { idempotencyKeySha256 } : {}),
  };
}

export function serviceAssertion(input: {
  keyBase64: string;
  issuer: "public-web" | "response-portal" | "review-console";
  audience: "submission-api" | "identity-api" | "billing-gateway";
  method: string;
  path: string;
  rawQuery?: string;
  body: string | Uint8Array;
  contentType: string;
  idempotencyKey?: string;
  nextSubmissionSession?: string;
}): string {
  const key = Buffer.from(input.keyBase64, "base64");
  if (key.length < 32) throw new Error("service assertion key is invalid");
  const nextSubmissionSession =
    input.nextSubmissionSession === undefined
      ? undefined
      : validNextSubmissionSession(input.nextSubmissionSession);
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    aud: input.audience,
    bodySha256: digest(input.body),
    contentType: input.body.length === 0 ? "" : input.contentType,
    exp: now + 30,
    iat: now,
    iss: input.issuer,
    jti: randomUUID(),
    method: input.method,
    ...(nextSubmissionSession
      ? {
          nextSubmissionSessionSha256: digest(nextSubmissionSession),
        }
      : {}),
    path: input.path,
    querySha256: digest(canonicalQuery(input.rawQuery ?? "")),
    typ: "service",
    v: 1,
  };
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const signingInput = `gurine-sa-v1.${digest(key).slice(0, 16)}.${payload}`;
  return `${signingInput}.${createHmac("sha256", key).update(signingInput).digest("base64url")}`;
}

export async function assertedJson(input: {
  fetch: typeof globalThis.fetch;
  baseUrl: string;
  keyBase64: string;
  issuer: "public-web" | "response-portal" | "review-console";
  audience: "submission-api" | "identity-api" | "billing-gateway";
  path: string;
  body: Record<string, unknown>;
  headers?: Record<string, string>;
}): Promise<{ response: Response; value: Record<string, unknown> }> {
  return assertedRequest({
    ...input,
    method: "POST",
    body: input.body,
    idempotency: true,
  });
}

export async function assertedRequest(input: {
  fetch: typeof globalThis.fetch;
  baseUrl: string;
  keyBase64: string;
  issuer: "public-web" | "response-portal" | "review-console";
  audience: "submission-api" | "identity-api" | "billing-gateway";
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  path: string;
  rawQuery?: string;
  body?: Record<string, unknown>;
  idempotency?: boolean;
  headers?: Record<string, string>;
}): Promise<{ response: Response; value: Record<string, unknown> }> {
  const bytes = input.body === undefined ? "" : JSON.stringify(input.body);
  const idempotencyKey = input.idempotency ? randomUUID() : undefined;
  const rawQuery = canonicalQuery(input.rawQuery ?? "");
  const nextSubmissionSession = nextSubmissionSessionFromRecord(input.headers);
  const assertion = serviceAssertion({
    keyBase64: input.keyBase64,
    issuer: input.issuer,
    audience: input.audience,
    method: input.method,
    path: input.path,
    ...(rawQuery ? { rawQuery } : {}),
    body: bytes,
    contentType: "application/json",
    ...(idempotencyKey ? { idempotencyKey } : {}),
    ...(nextSubmissionSession ? { nextSubmissionSession } : {}),
  });
  const response = await input.fetch(
    `${input.baseUrl.replace(/\/$/, "")}${input.path}${rawQuery ? `?${rawQuery}` : ""}`,
    {
      method: input.method,
      headers: {
        ...(bytes ? { "content-type": "application/json" } : {}),
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
        "x-gurine-service-assertion": assertion,
        "x-request-id": randomUUID(),
        ...input.headers,
      },
      ...(bytes ? { body: bytes } : {}),
    },
  );
  const text = await response.text();
  let value: unknown = text === "" ? {} : JSON.parse(text);
  if (typeof value !== "object" || value === null || Array.isArray(value))
    value = {};
  return { response, value: value as Record<string, unknown> };
}

export function canonicalizeRequestQuery(request: Request): {
  request: Request;
  rawQuery: string;
} {
  const url = new URL(request.url);
  const rawQuery = canonicalQuery(
    url.search.length > 1 ? url.search.slice(1) : "",
  );
  url.search = rawQuery ? `?${rawQuery}` : "";
  return { request: new Request(url, request), rawQuery };
}

export function serviceAssertionFetch(input: {
  fetch: typeof globalThis.fetch;
  keyBase64: string;
  issuer: "public-web" | "response-portal" | "review-console";
  audience: "submission-api" | "identity-api" | "billing-gateway";
  additionalHeaders?: Record<string, string>;
}): typeof globalThis.fetch {
  return async (resource, init) => {
    const original =
      resource instanceof Request ? resource : new Request(resource, init);
    const { request, rawQuery } = canonicalizeRequestQuery(original);
    const url = new URL(request.url);
    const body = new Uint8Array(await request.clone().arrayBuffer());
    const idempotencyKey = request.headers.get("idempotency-key") ?? undefined;
    const requestNextSubmissionSession = nextSubmissionSessionFromHeaders(
      request.headers,
    );
    const additionalNextSubmissionSession = nextSubmissionSessionFromRecord(
      input.additionalHeaders,
    );
    if (requestNextSubmissionSession && additionalNextSubmissionSession)
      throw new Error("duplicate next submission session header");
    const nextSubmissionSession =
      requestNextSubmissionSession ?? additionalNextSubmissionSession;
    const assertion = serviceAssertion({
      keyBase64: input.keyBase64,
      issuer: input.issuer,
      audience: input.audience,
      method: request.method,
      path: url.pathname,
      ...(rawQuery ? { rawQuery } : {}),
      body,
      contentType: request.headers.get("content-type") ?? "",
      ...(idempotencyKey ? { idempotencyKey } : {}),
      ...(nextSubmissionSession ? { nextSubmissionSession } : {}),
    });
    const headers = new Headers(request.headers);
    headers.set("x-gurine-service-assertion", assertion);
    headers.set("x-request-id", randomUUID());
    for (const [name, value] of Object.entries(input.additionalHeaders ?? {}))
      headers.set(name, value);
    return input.fetch(new Request(request, { headers }));
  };
}

function nextSubmissionSessionFromHeaders(
  headers: Headers,
): string | undefined {
  const value = headers.get(NEXT_SUBMISSION_SESSION_HEADER);
  return value === null ? undefined : validNextSubmissionSession(value);
}

function nextSubmissionSessionFromRecord(
  headers: Record<string, string> | undefined,
): string | undefined {
  const matches = Object.entries(headers ?? {}).filter(
    ([name]) => name.toLowerCase() === NEXT_SUBMISSION_SESSION_HEADER,
  );
  if (matches.length > 1)
    throw new Error("duplicate next submission session header");
  const value = matches[0]?.[1];
  return value === undefined ? undefined : validNextSubmissionSession(value);
}

function validNextSubmissionSession(value: string): string {
  if (!SUBMISSION_SESSION_TOKEN.test(value))
    throw new Error("next submission session header is invalid");
  return value;
}

function canonicalQuery(raw: string): string {
  if (raw === "") return "";
  const pairs = raw.split("&").map((part) => {
    const [key = "", value = ""] = part.split("=", 2);
    return [decodeFormComponent(key), decodeFormComponent(value)] as const;
  });
  pairs.sort(([leftKey, leftValue], [rightKey, rightValue]) => {
    const keyOrder = compareUtf8(leftKey, rightKey);
    return keyOrder === 0 ? compareUtf8(leftValue, rightValue) : keyOrder;
  });
  return pairs
    .map(([key, value]) => `${strictEncode(key)}=${strictEncode(value)}`)
    .join("&");
}

function decodeFormComponent(value: string): string {
  return decodeURIComponent(value.replaceAll("+", "%20"));
}

function compareUtf8(left: string, right: string): number {
  return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
}

function strictEncode(value: string): string {
  return encodeURIComponent(value).replaceAll(
    /[!'()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}
