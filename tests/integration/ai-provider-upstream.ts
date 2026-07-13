const port = Number(required("AI_PROVIDER_TEST_PORT"));
const expectedKey = required("AI_PROVIDER_EXPECTED_KEY");

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
    const body = (await request.json()) as {
      evidence?: Array<{ id?: string; locator?: string }>;
    };
    const evidence = body.evidence?.[0];
    if (!evidence?.id || !evidence.locator) {
      return Response.json({ code: "evidence_missing" }, { status: 400 });
    }
    return Response.json({
      output: {
        status: "COMPLETED",
        summary:
          "승인된 고정 근거 snapshot만 검토했으며 독립적인 사람 검토가 필요합니다.",
        citations: [
          {
            evidence_id: evidence.id,
            locator: evidence.locator,
            supports: "검증된 provider egress runtime 근거",
          },
        ],
        unknowns: [],
        abstention_reasons: [],
        recommended_actions: [],
      },
      costKrw: 17,
    });
  },
});

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
}
