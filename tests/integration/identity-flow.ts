import { createHash, createHmac, randomUUID } from "node:crypto";

const identityBase = required("IDENTITY_TEST_BASE_URL");
const egressBase = required("EGRESS_TEST_BASE_URL");
const serviceKey = Buffer.from(
  required("IDENTITY_SERVICE_HMAC_KEY_CURRENT"),
  "base64",
);

if (serviceKey.length < 32)
  throw new Error("identity service test key is too short");

const sha256 = (value: string | Buffer): string =>
  createHash("sha256").update(value).digest("hex");

function serviceAssertion(path: string, body: string): string {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    aud: "identity-api",
    bodySha256: sha256(body),
    contentType: "application/json",
    exp: now + 30,
    iat: now,
    iss: "review-console",
    jti: randomUUID(),
    method: "POST",
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

type Invocation = {
  body: Record<string, unknown>;
  response: Response;
};

async function invoke(
  path: string,
  value: Record<string, unknown>,
  options: {
    expected?: number;
    idempotencyKey?: string;
    assertion?: string;
  } = {},
): Promise<Invocation> {
  const body = JSON.stringify(value);
  const response = await fetch(`${identityBase}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "idempotency-key": options.idempotencyKey ?? randomUUID(),
      "x-gurine-service-assertion":
        options.assertion ?? serviceAssertion(path, body),
      "x-request-id": randomUUID(),
    },
    body,
  });
  const text = await response.text();
  const parsed = text === "" ? {} : parseRecord(text);
  const expected = options.expected ?? 200;
  if (response.status !== expected) {
    throw new Error(
      `${path}: expected ${expected}, got ${response.status}: ${text}`,
    );
  }
  return { body: parsed, response };
}

async function authorizationCallback(authorizationUrl: string): Promise<URL> {
  const response = await fetch(authorizationUrl, { redirect: "manual" });
  equal(response.status, 303, "synthetic OIDC authorization status");
  const location = response.headers.get("location");
  if (location === null)
    throw new Error("synthetic OIDC authorization omitted Location");
  return new URL(location);
}

const context = {
  ipHash: "c".repeat(64),
  userAgentHash: "d".repeat(64),
  requestId: randomUUID(),
};

const denied = await fetch(`${egressBase}/oidc`, {
  headers: {
    "x-gurine-egress-target":
      "https://example.com/.well-known/openid-configuration",
  },
});
equal(denied.status, 403, "OIDC egress host allowlist");

const createPath = "/internal/v1/oidc/login-transactions";
const createBody = {
  returnTo: "/internal",
  callbackUri: "http://localhost:3001/auth/callback",
  context,
};
const createBytes = JSON.stringify(createBody);
const replayKey = randomUUID();
const firstCreate = await invoke(createPath, createBody, {
  idempotencyKey: replayKey,
});
const replayCreate = await invoke(createPath, createBody, {
  idempotencyKey: replayKey,
});
equal(
  replayCreate.response.headers.get("idempotent-replay"),
  "true",
  "idempotent replay header",
);
equal(
  replayCreate.body.authorizationUrl,
  firstCreate.body.authorizationUrl,
  "idempotent response body",
);

const reusedAssertion = serviceAssertion(createPath, createBytes);
await invoke(createPath, createBody, { assertion: reusedAssertion });
await invoke(createPath, createBody, {
  assertion: reusedAssertion,
  expected: 409,
});

const loginCreated = await invoke(createPath, createBody);
const loginCallback = await authorizationCallback(
  stringField(loginCreated.body, "authorizationUrl"),
);
const loginRequest = {
  transactionCookieValue: stringField(
    loginCreated.body,
    "transactionCookieValue",
  ),
  code: requiredSearch(loginCallback, "code"),
  state: requiredSearch(loginCallback, "state"),
  issuer: requiredSearch(loginCallback, "iss"),
  context,
};
const loggedIn = await invoke(
  "/internal/v1/oidc/login-callbacks",
  loginRequest,
);
await invoke("/internal/v1/oidc/login-callbacks", loginRequest, {
  expected: 409,
});

const opaqueSessionToken = stringField(loggedIn.body, "opaqueSessionToken");
const originalCsrf = stringField(loggedIn.body, "csrfToken");
const capabilityFreeBody = "{}";
const capabilityFreeIdempotency = randomUUID();
const capabilityFreePath = "/v1/internal/commands/revoke-own-session";
const capabilityFreeQuerySha256 = sha256("");
const capabilityFreeBodySha256 = sha256(capabilityFreeBody);
const capabilityFreeIdempotencySha256 = sha256(capabilityFreeIdempotency);
const capabilityFreeIssued = await invoke("/internal/v1/actor-assertions", {
  opaqueSessionToken,
  downstreamRequest: {
    method: "POST",
    normalizedPath: capabilityFreePath,
    querySha256: capabilityFreeQuerySha256,
    bodySha256: capabilityFreeBodySha256,
    contentType: "application/json",
    requestDigest: sha256(
      `POST\n${capabilityFreePath}\n${capabilityFreeQuerySha256}\n${capabilityFreeBodySha256}\napplication/json\n${capabilityFreeIdempotencySha256}`,
    ),
    idempotencyKeySha256: capabilityFreeIdempotencySha256,
  },
  operationId: "revokeOwnSession",
  requiredCapability: "none",
  context,
  requiredAssuranceLevel: "ACTIVE_SESSION",
});
const capabilityFreeAssertion = stringField(
  capabilityFreeIssued.body,
  "actorAssertion",
);
const capabilityFreeClaims = parseRecord(
  Buffer.from(
    capabilityFreeAssertion.split(".")[2] ?? "",
    "base64url",
  ).toString("utf8"),
);
equal(
  capabilityFreeClaims.requiredCapability,
  "none",
  "capability-free assertion contract",
);
if (
  !Array.isArray(capabilityFreeClaims.capabilities) ||
  capabilityFreeClaims.capabilities.includes("none")
) {
  throw new Error("capability-free assertion invented a role capability");
}
const downstreamIdempotency = randomUUID();
const downstreamBody = JSON.stringify({
  killSwitchId: randomUUID(),
  expectedVersion: 1,
  reason: "identity integration test",
  expiresAt: null,
});
const actionContext = {
  operationId: "activateKillSwitch",
  aggregateType: "ops.kill_switch",
  aggregateId: randomUUID(),
  expectedVersion: 1,
  businessPayloadSha256: sha256(downstreamBody),
  idempotencyKeySha256: sha256(downstreamIdempotency),
};
const stepUpRequest = {
  opaqueSessionToken,
  csrfToken: originalCsrf,
  returnTo: "/internal/operations/kill-switches",
  callbackUri: "http://localhost:3001/auth/step-up/callback",
  context,
  actionContext,
};
const stepUpCreated = await invoke(
  "/internal/v1/oidc/step-up-transactions",
  stepUpRequest,
);
const stepUpCallback = await authorizationCallback(
  stringField(stepUpCreated.body, "authorizationUrl"),
);
const elevated = await invoke("/internal/v1/oidc/step-up-callbacks", {
  opaqueSessionToken,
  transactionCookieValue: stringField(
    stepUpCreated.body,
    "transactionCookieValue",
  ),
  code: requiredSearch(stepUpCallback, "code"),
  state: requiredSearch(stepUpCallback, "state"),
  issuer: requiredSearch(stepUpCallback, "iss"),
  context,
});
await invoke("/internal/v1/oidc/step-up-transactions", stepUpRequest, {
  expected: 403,
});

const querySha256 = sha256("");
const bodySha256 = sha256(downstreamBody);
const idempotencyKeySha256 = sha256(downstreamIdempotency);
const normalizedPath = "/v1/internal/commands/activate-kill-switch";
const downstreamRequest = {
  method: "POST",
  normalizedPath,
  querySha256,
  bodySha256,
  contentType: "application/json",
  requestDigest: sha256(
    `POST\n${normalizedPath}\n${querySha256}\n${bodySha256}\napplication/json\n${idempotencyKeySha256}`,
  ),
  idempotencyKeySha256,
};
const issueRequest = {
  opaqueSessionToken,
  downstreamRequest,
  operationId: "activateKillSwitch",
  requiredCapability: "kill_switch.execute",
  actionContext,
  actionDigest: stringField(elevated.body, "actionDigest"),
  stepUpAuthorizationToken: stringField(
    elevated.body,
    "stepUpAuthorizationToken",
  ),
  context,
  requiredAssuranceLevel: "STEP_UP",
};
const mismatchedBodySha256 = sha256(`${downstreamBody}\n`);
const mismatchedDownstreamRequest = {
  ...downstreamRequest,
  bodySha256: mismatchedBodySha256,
  requestDigest: sha256(
    `POST\n${normalizedPath}\n${querySha256}\n${mismatchedBodySha256}\napplication/json\n${idempotencyKeySha256}`,
  ),
};
const mismatchedIssueRequest = {
  ...issueRequest,
  downstreamRequest: mismatchedDownstreamRequest,
};
const mismatchedIssueKey = randomUUID();
await invoke("/internal/v1/actor-assertions", mismatchedIssueRequest, {
  expected: 401,
  idempotencyKey: mismatchedIssueKey,
});
await invoke("/internal/v1/actor-assertions", mismatchedIssueRequest, {
  expected: 401,
  idempotencyKey: mismatchedIssueKey,
});
const remaining: number[] = [];
for (let index = 0; index < 3; index += 1) {
  const issued = await invoke("/internal/v1/actor-assertions", issueRequest);
  remaining.push(numberField(issued.body, "remainingAssertionIssues"));
  if (!stringField(issued.body, "actorAssertion").startsWith("gurine-aa-v1.")) {
    throw new Error("actor assertion prefix is invalid");
  }
}
equal(
  JSON.stringify(remaining),
  JSON.stringify([2, 1, 0]),
  "bounded assertion issues",
);
await invoke("/internal/v1/actor-assertions", issueRequest, { expected: 403 });

const closed = await invoke("/internal/v1/step-up-authorizations/close", {
  opaqueSessionToken,
  stepUpAuthorizationToken: stringField(
    elevated.body,
    "stepUpAuthorizationToken",
  ),
  actionDigest: stringField(elevated.body, "actionDigest"),
  idempotencyKeySha256: stringField(elevated.body, "idempotencyKeySha256"),
  context,
});
equal(closed.body.closed, true, "step-up authorization close");

const resolved = await invoke("/internal/v1/sessions/resolve", {
  opaqueSessionToken,
  context,
});
const actor = recordField(resolved.body, "actor");
equal(
  actor.userId,
  "11111111-1111-4111-8111-111111111111",
  "resolved OIDC subject",
);
equal(
  resolved.body.csrfTokenReturned,
  false,
  "session resolve CSRF disclosure",
);
if (stringField(elevated.body, "csrfToken") === originalCsrf) {
  throw new Error("successful step-up did not rotate CSRF");
}

await invoke("/internal/v1/sessions/revoke", {
  opaqueSessionToken,
  reason: "identity integration test complete",
  context,
});
await invoke(
  "/internal/v1/sessions/resolve",
  { opaqueSessionToken, context },
  { expected: 401 },
);

console.log("identity OIDC/session/CSRF/step-up/assertion integration: PASS");

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

function stringField(value: Record<string, unknown>, name: string): string {
  const field = value[name];
  if (typeof field !== "string") throw new Error(`${name} is not a string`);
  return field;
}

function numberField(value: Record<string, unknown>, name: string): number {
  const field = value[name];
  if (typeof field !== "number") throw new Error(`${name} is not a number`);
  return field;
}

function requiredSearch(value: URL, name: string): string {
  const field = value.searchParams.get(name);
  if (field === null || field === "")
    throw new Error(`callback omitted ${name}`);
  return field;
}

function equal(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${String(expected)}, got ${String(actual)}`,
    );
  }
}
