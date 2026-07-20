const port = Number(required("AI_PROVIDER_TEST_PORT"));
const expectedKey = required("AI_PROVIDER_EXPECTED_KEY");
const evidenceId = process.env.AI_PROVIDER_EVIDENCE_ID;
const evidenceLocator = process.env.AI_PROVIDER_EVIDENCE_LOCATOR ?? "page:7";
const expectedContentB64 = process.env.AI_PROVIDER_EXPECTED_CONTENT_B64;
const expectedContentSha256 = process.env.AI_PROVIDER_EXPECTED_CONTENT_SHA256;

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return Response.json({ status: "ready" });
    if (url.pathname !== "/agent" || request.method !== "POST") {
      return new Response("not found", { status: 404 });
    }
    if (request.headers.get("authorization") !== `Bearer ${expectedKey}`) {
      return Response.json({ code: "credential_missing" }, { status: 401 });
    }
    if (
      request.headers.has("x-gurine-egress-caller") ||
      request.headers.has("x-gurine-egress-target") ||
      request.headers.has("x-gurine-ai-provider")
    ) {
      return Response.json({ code: "internal_header_leak" }, { status: 400 });
    }
    const body = (await request.json()) as Record<string, unknown>;
    if (body.operation === "connection_test") {
      return Response.json({ status: "ok", model: body.model });
    }
    const requiredFields = [
      "schemaVersion",
      "objectiveSha256",
      "messageCount",
      "authorizedSegmentCount",
      "orderedSourceUseIds",
      "toolChoice",
      "maxOutputUnits",
      "semanticRequestSha256",
      "redactionReceiptSha256",
    ];
    if (
      requiredFields.some((field) => !(field in body)) ||
      body.schemaVersion !== "agent-provider-request-redacted.v2" ||
      !Array.isArray(body.orderedSourceUseIds) ||
      body.toolChoice !== "AUTO_ALLOWLIST"
    ) {
      return Response.json(
        { code: "request_redacted_invalid" },
        { status: 400 },
      );
    }
    const selectedContentRefs = body.selectedContentRefs;
    if (
      !Array.isArray(selectedContentRefs) ||
      selectedContentRefs.length === 0
    ) {
      return Response.json(
        { code: "selected_content_bytes_missing" },
        { status: 400 },
      );
    }
    for (const reference of selectedContentRefs) {
      const item = reference as Record<string, unknown>;
      if (
        typeof item.sourceUseId !== "string" ||
        typeof item.selectedContentBytesBase64 !== "string" ||
        typeof item.selectedContentSha256 !== "string" ||
        typeof item.selectedContentSizeBytes !== "number" ||
        "selectedContentObjectKey" in item
      ) {
        return Response.json(
          { code: "selected_content_capsule_invalid" },
          { status: 400 },
        );
      }
      if (
        expectedContentB64 &&
        item.selectedContentBytesBase64 !== expectedContentB64
      ) {
        return Response.json(
          { code: "selected_content_bytes_mismatch" },
          { status: 400 },
        );
      }
      if (
        expectedContentSha256 &&
        item.selectedContentSha256 !== expectedContentSha256
      ) {
        return Response.json(
          { code: "selected_content_digest_mismatch" },
          { status: 400 },
        );
      }
      const decoded = Uint8Array.from(
        atob(item.selectedContentBytesBase64),
        (value) => value.charCodeAt(0),
      );
      if (decoded.byteLength !== item.selectedContentSizeBytes) {
        return Response.json(
          { code: "selected_content_size_mismatch" },
          { status: 400 },
        );
      }
      if (expectedContentSha256) {
        const hasher = new Bun.CryptoHasher("sha256");
        hasher.update(decoded);
        if (hasher.digest("hex") !== expectedContentSha256) {
          return Response.json(
            { code: "selected_content_hash_mismatch" },
            { status: 400 },
          );
        }
      }
    }
    const runId = request.headers.get("x-gurine-ai-agent-run-id");
    const turnId = request.headers.get("x-gurine-ai-provider-turn-id");
    const inputSnapshotId = request.headers.get(
      "x-gurine-ai-input-snapshot-id",
    );
    const inputSnapshotSha256 = request.headers.get(
      "x-gurine-ai-input-snapshot-sha256",
    );
    const providerConfigId = request.headers.get(
      "x-gurine-ai-provider-config-id",
    );
    const modelId = request.headers.get("x-gurine-ai-model-id");
    const modelConfigurationSha256 = request.headers.get(
      "x-gurine-ai-model-configuration-sha256",
    );
    const idempotencyKeySha256 = request.headers.get(
      "x-gurine-ai-idempotency-key-sha256",
    );
    if (
      !runId ||
      !turnId ||
      !providerConfigId ||
      !modelId ||
      !modelConfigurationSha256 ||
      !idempotencyKeySha256 ||
      !inputSnapshotId ||
      !inputSnapshotSha256
    ) {
      return Response.json(
        { code: "binding_headers_missing" },
        { status: 400 },
      );
    }
    const now = new Date().toISOString();
    const turnSequence = Number(body.turnSequence ?? 1);
    const toolTurn = turnSequence === 1;
    const agentType =
      request.headers.get("x-gurine-ai-agent-type") ?? "investigator";
    const toolId = ["claim-drafter", "citation-verifier"].includes(agentType)
      ? "evidence.read"
      : "evidence.search";
    const providerRequestIdHash = sha256Hex(
      `runtime-provider-request:${turnId}`,
    );
    const receipt: Record<string, unknown> = {
      schemaVersion: "provider-receipt.v2",
      receiptId: crypto.randomUUID(),
      agentRunId: runId,
      providerTurnId: turnId,
      providerMode: "EXTERNAL_APPROVED",
      providerConfigId,
      providerCandidateId: "openai",
      modelId,
      modelConfigurationSha256,
      semanticRequestSha256: body.semanticRequestSha256,
      idempotencyKeySha256,
      outcome: toolTurn ? "ACCEPTED_TOOL_CALL" : "ACCEPTED_FINAL",
      proofKind: "AUTHENTICATED_RESPONSE_HEADERS",
      proofSha256: sha256Hex(providerRequestIdHash),
      providerRequestIdHash,
      usage: {
        state: "PROVIDER_REPORTED",
        inputUnits: 1,
        outputUnits: 1,
        cachedInputUnits: 0,
        billableUnits: 2,
        usageEvidenceSha256: sha256Hex("runtime-usage"),
      },
      pricing: {
        pricingVersion: "runtime-v1",
        pricingSha256: sha256Hex(
          canonical({
            currency: "KRW",
            inputMicrosKrwPerUnit: 8_500_000,
            outputMicrosKrwPerUnit: 8_500_000,
            pricingVersion: "runtime-v1",
          }),
        ),
        currency: "KRW",
        fxRateFactId: null,
        reservedMicrosKrw: 17_000_000,
        actualMicrosKrw: 17_000_000,
        costState: "SETTLED",
      },
      dataPolicy: {
        classification: "INTERNAL",
        processingRegion: "US",
        retentionMode: "ZERO_RETENTION",
        trainingUse: "PROHIBITED",
        policyVersion: "runtime-v1",
        policySha256: sha256Hex("runtime-policy-v1"),
        rightsDecisionSetSha256: sha256Hex("runtime-rights-v1"),
      },
      dispatchedAt: now,
      observedAt: now,
      completedAt: now,
    };
    receipt.receiptSha256 = sha256Hex(canonical(receipt));
    if (toolTurn) {
      const binding = {
        schemaVersion:
          toolId === "evidence.read"
            ? "evidence.read.request.v2"
            : "evidence.search.request.v2",
        runId,
        inputSnapshotId,
        inputSnapshotSha256,
        ...(toolId === "evidence.read"
          ? {
              evidenceId: evidenceId,
              evidenceVersion: 1,
              requestedSegmentIds: [],
              includePublicExcerpt: true,
              maxCharacters: 4000,
            }
          : {
              query: "runtime",
              queryLanguage: "ko",
              evidenceTypes: ["DOCUMENT"],
              verificationStates: ["VERIFIED"],
              classifications: ["PUBLIC"],
              sourceAuthorities: [],
              sort: "RELEVANCE",
              cursor: null,
              limit: 20,
            }),
      };
      return Response.json({
        toolCall: {
          callId: `runtime-${turnId}`,
          toolId,
          request: binding,
        },
        providerReceipt: receipt,
      });
    }
    const firstReference = selectedContentRefs[0] as Record<string, unknown>;
    const citation = expectedContentSha256
      ? [
          {
            ...(agentType === "claim-drafter"
              ? { citationId: "41000000-0000-4000-8000-000000000010" }
              : {}),
            sourceUseSha256: firstReference.sourceUseSha256,
            locator: {
              kind: "TEXT_RANGE",
              value: evidenceLocator,
              locatorSha256: firstReference.locatorSha256,
            },
            selectedContentSha256: expectedContentSha256,
            supports: "검증된 provider egress runtime 근거",
            supportsSha256: sha256Hex("검증된 provider egress runtime 근거"),
          },
        ]
      : [];
    const output: Record<string, unknown> = {
      schemaVersion: "investigator-output.v2",
      outcome: "COMPLETED",
      summary:
        "승인된 고정 근거 snapshot만 검토했으며 독립적인 사람 검토가 필요합니다.",
      citations: citation,
      unknowns: [],
      nextActions: [],
      abstentionReasons: [],
      investigationsPerformed: [],
    };
    const agentOutputShape: Record<string, Record<string, unknown>> = {
      "market-researcher": {
        schemaVersion: "market-research-output.v2",
        comparables: [],
      },
      investigator: {
        schemaVersion: "investigator-output.v2",
        hypotheses: [],
        counterEvidence: [],
        tasks: [],
      },
      skeptic: {
        schemaVersion: "skeptic-output.v2",
        challenges: [],
      },
      "claim-drafter": {
        schemaVersion: "claim-draft-output.v2",
        claims: [],
        communications: [],
      },
      "citation-verifier": {
        schemaVersion: "citation-verification-output.v2",
        claimResults: [],
      },
    };
    Object.assign(
      output,
      agentOutputShape[agentType] ?? agentOutputShape.investigator,
    );
    return Response.json({
      output,
      providerReceipt: receipt,
      costKrw: 17,
    });
  },
});

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number")
    return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonical(object[key])}`)
    .join(",")}}`;
}

function sha256Hex(value: string): string {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(value);
  return hasher.digest("hex");
}
