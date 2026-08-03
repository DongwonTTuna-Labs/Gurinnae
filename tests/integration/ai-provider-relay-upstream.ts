interface RelayCompletionContext {
  evidenceId: string | undefined;
  agentOutput: (
    agentType: string,
    selectedContentRefs: unknown[],
  ) => Record<string, unknown>;
}

export async function handleRelayCompletion(
  request: Request,
  context: RelayCompletionContext,
): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  if (typeof body.model !== "string" || !Array.isArray(body.messages)) {
    return Response.json({ code: "relay_request_invalid" }, { status: 400 });
  }
  const userMessage = body.messages.findLast(
    (message) =>
      typeof message === "object" &&
      message !== null &&
      (message as Record<string, unknown>).role === "user",
  ) as Record<string, unknown> | undefined;
  if (!userMessage || typeof userMessage.content !== "string") {
    return Response.json({ code: "relay_messages_invalid" }, { status: 400 });
  }
  let user: Record<string, unknown>;
  try {
    user = JSON.parse(userMessage.content) as Record<string, unknown>;
  } catch {
    return Response.json(
      { code: "relay_user_content_invalid" },
      { status: 400 },
    );
  }
  const bindings = user.bindings as Record<string, unknown> | undefined;
  if (!bindings) return openAiCompletion(body.model, { status: "ok" });
  const agentType = bindings.agentType;
  const selectedContentRefs = user.selectedContentRefs;
  if (
    typeof agentType !== "string" ||
    typeof bindings.agentRunId !== "string" ||
    typeof bindings.inputSnapshotId !== "string" ||
    typeof bindings.inputSnapshotSha256 !== "string" ||
    !Array.isArray(selectedContentRefs)
  ) {
    return Response.json({ code: "relay_bindings_invalid" }, { status: 400 });
  }
  const toolId = ["claim-drafter", "citation-verifier"].includes(agentType)
    ? "evidence.read"
    : "evidence.search";
  if (bindings.turnSequence === 1) {
    return relayToolCompletion(body, bindings, toolId, context.evidenceId);
  }
  return openAiCompletion(
    body.model,
    context.agentOutput(agentType, selectedContentRefs),
  );
}

function relayToolCompletion(
  body: Record<string, unknown> & { model: string },
  bindings: Record<string, unknown>,
  toolId: string,
  evidenceId: string | undefined,
): Response {
  const toolName = reversibleToolName(toolId);
  const advertised = Array.isArray(body.tools)
    ? body.tools.some(
        (tool) =>
          typeof tool === "object" &&
          tool !== null &&
          (tool as Record<string, unknown>).type === "function" &&
          (
            (tool as Record<string, unknown>).function as
              | Record<string, unknown>
              | undefined
          )?.name === toolName,
      )
    : false;
  if (!advertised) {
    return Response.json({ code: "relay_tool_missing" }, { status: 400 });
  }
  return openAiToolCompletion(body.model, toolName, {
    schemaVersion:
      toolId === "evidence.read"
        ? "evidence.read.request.v2"
        : "evidence.search.request.v2",
    runId: bindings.agentRunId,
    inputSnapshotId: bindings.inputSnapshotId,
    inputSnapshotSha256: bindings.inputSnapshotSha256,
    ...(toolId === "evidence.read"
      ? {
          evidenceId,
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
  });
}

function openAiCompletion(model: string, output: Record<string, unknown>) {
  return openAiResponse(
    model,
    { role: "assistant", content: JSON.stringify(output) },
    "stop",
  );
}

function openAiToolCompletion(
  model: string,
  name: string,
  request: Record<string, unknown>,
) {
  return openAiResponse(
    model,
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: `call-${crypto.randomUUID()}`,
          type: "function",
          function: { name, arguments: JSON.stringify(request) },
        },
      ],
    },
    "tool_calls",
  );
}

function openAiResponse(
  model: string,
  message: Record<string, unknown>,
  finishReason: string,
) {
  return Response.json({
    id: `chatcmpl-${crypto.randomUUID()}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message, finish_reason: finishReason }],
    usage: {
      prompt_tokens: 1,
      completion_tokens: 1,
      total_tokens: 2,
      prompt_tokens_details: { cached_tokens: 0 },
    },
  });
}

function reversibleToolName(toolId: string): string {
  return toolId.replaceAll(".", "__dot__");
}
