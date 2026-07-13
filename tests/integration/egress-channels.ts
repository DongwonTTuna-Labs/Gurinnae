import { createHash } from "node:crypto";

const gateway = required("EGRESS_TEST_BASE_URL");
const upstream = required("EGRESS_TEST_UPSTREAM_URL");

async function channel(
  route: string,
  caller: string,
  target: string,
  method: string,
  body?: string,
  internal?: Record<string, string>,
): Promise<Response> {
  return fetch(`${gateway}${route}`, {
    method,
    headers: {
      "content-type": "application/json",
      "x-gurine-egress-caller": caller,
      "x-gurine-egress-target": target,
      ...internal,
    },
    body,
    redirect: "manual",
  });
}

equal(
  (
    await fetch(`${gateway}/source`, {
      headers: { "x-gurine-egress-target": `${upstream}/source` },
    })
  ).status,
  403,
  "caller required",
);
equal(
  (await channel("/source", "ingest-worker", "https://example.com", "GET"))
    .status,
  403,
  "source host denied",
);
const source = await channel(
  "/source",
  "ingest-worker",
  `${upstream}/source`,
  "GET",
  undefined,
  {
    "x-gurine-source-id": "koneps-contracts",
    authorization: "Bearer caller-secret",
  },
);
equal(source.status, 200, "source channel");
const sourcePayload = (await source.json()) as {
  channel: string;
  credentialValid: boolean;
  callerCredentialStripped: boolean;
  internalHeadersPresent: boolean;
};
equal(sourcePayload.channel, "source", "source response");
equal(sourcePayload.credentialValid, true, "source credential injection");
equal(
  sourcePayload.callerCredentialStripped,
  true,
  "source caller credential stripping",
);
equal(
  sourcePayload.internalHeadersPresent,
  false,
  "source internal header stripping",
);
equal(
  (
    await channel(
      "/source",
      "ingest-worker",
      `${upstream}/source`,
      "POST",
      "{}",
      {
        "x-gurine-source-id": "koneps-contracts",
      },
    )
  ).status,
  405,
  "source method denied",
);
const aiBody = JSON.stringify({ model: "test", input: "bound" });
const ai = await channel(
  "/ai",
  "analysis-worker",
  `${upstream}/ai`,
  "POST",
  aiBody,
  {
    "x-gurine-ai-provider": "openai",
    authorization: "Bearer caller-secret",
  },
);
equal(ai.status, 200, "AI channel");
const aiPayload = (await ai.json()) as {
  body: unknown;
  credentialValid: boolean;
  callerOverrideReplaced: boolean;
  internalHeadersPresent: boolean;
};
equal(JSON.stringify(aiPayload.body), aiBody, "AI body forwarding");
equal(aiPayload.credentialValid, true, "AI credential injection");
equal(
  aiPayload.callerOverrideReplaced,
  true,
  "AI caller credential replacement",
);
equal(aiPayload.internalHeadersPresent, false, "AI internal header stripping");
equal(
  (
    await channel("/ai", "analysis-worker", `${upstream}/ai`, "POST", aiBody, {
      "x-gurine-ai-provider": "google",
    })
  ).status,
  503,
  "missing provider credential fails closed",
);
const challenge = await channel(
  "/challenge",
  "submission-api",
  `${upstream}/challenge`,
  "POST",
  "secret=x&response=y",
);
equal(challenge.status, 200, "challenge channel");
equal(
  (
    await channel(
      "/source",
      "ingest-worker",
      `${upstream}/redirect`,
      "GET",
      undefined,
      {
        "x-gurine-source-id": "koneps-contracts",
      },
    )
  ).status,
  502,
  "redirect denied",
);

const objectBytes = Buffer.from("egress-object-store-integration");
const objectHash = createHash("sha256").update(objectBytes).digest("hex");
const objectHeaders = {
  "x-gurine-egress-caller": "workflow-worker",
  "x-gurine-object-key": "integration/object.bin",
  "x-gurine-object-sha256": objectHash,
};
equal(
  (
    await fetch(`${gateway}/object-store`, {
      method: "PUT",
      headers: objectHeaders,
      body: objectBytes,
    })
  ).status,
  204,
  "object PUT",
);
const objectGet = await fetch(`${gateway}/object-store`, {
  headers: objectHeaders,
});
equal(objectGet.status, 200, "object GET");
equal(
  Buffer.compare(Buffer.from(await objectGet.arrayBuffer()), objectBytes),
  0,
  "object bytes",
);
equal(
  (
    await fetch(`${gateway}/object-store`, {
      method: "HEAD",
      headers: objectHeaders,
    })
  ).status,
  200,
  "object HEAD",
);
equal(
  (
    await fetch(`${gateway}/object-store`, {
      method: "GET",
      headers: { ...objectHeaders, "x-gurine-egress-caller": "identity-api" },
    })
  ).status,
  403,
  "object caller denied",
);
equal(
  (
    await fetch(`${gateway}/object-store`, {
      method: "DELETE",
      headers: objectHeaders,
    })
  ).status,
  204,
  "object DELETE",
);

console.log(
  "egress caller/host/method/DNS-pin/redirect/object-store integration: PASS",
);

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") throw new Error(`missing ${name}`);
  return value;
}

function equal(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected)
    throw new Error(
      `${label}: expected ${String(expected)}, got ${String(actual)}`,
    );
}
