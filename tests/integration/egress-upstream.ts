const port = Number(process.env.EGRESS_UPSTREAM_PORT ?? "28086");
const dataKey = process.env.EGRESS_EXPECTED_DATA_KEY ?? "";
const openaiKey = process.env.EGRESS_EXPECTED_OPENAI_KEY ?? "";

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/redirect") {
      return new Response(null, {
        status: 302,
        headers: { location: "/source" },
      });
    }
    if (url.pathname === "/source" && request.method === "GET") {
      return Response.json({
        channel: "source",
        credentialValid: url.searchParams.get("serviceKey") === dataKey,
        callerCredentialStripped: !request.headers.has("authorization"),
        internalHeadersPresent:
          request.headers.has("x-gurine-egress-caller") ||
          request.headers.has("x-gurine-source-id"),
      });
    }
    if (url.pathname === "/ai" && request.method === "POST") {
      return Response.json({
        body: await request.json(),
        credentialValid:
          request.headers.get("authorization") === `Bearer ${openaiKey}`,
        callerOverrideReplaced:
          request.headers.get("authorization") !== "Bearer caller-secret",
        internalHeadersPresent:
          request.headers.has("x-gurine-egress-caller") ||
          request.headers.has("x-gurine-ai-provider"),
      });
    }
    if (url.pathname === "/challenge" && request.method === "POST") {
      return Response.json({ success: true, action: "createContactRequest" });
    }
    return new Response("not found", { status: 404 });
  },
});
