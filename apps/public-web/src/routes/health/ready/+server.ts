import { env } from "$env/dynamic/private";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async ({ fetch }) =>
  dependencyReady(fetch, env.PUBLIC_API_INTERNAL_URL);

async function dependencyReady(
  fetcher: typeof fetch,
  base: string | undefined,
): Promise<Response> {
  if (!base) return Response.json({ status: "not-ready" }, { status: 503 });
  try {
    const response = await fetcher(`${base.replace(/\/$/, "")}/health/ready`, {
      signal: AbortSignal.timeout(2_000),
    });
    return Response.json(
      { status: response.ok ? "ready" : "not-ready" },
      { status: response.ok ? 200 : 503 },
    );
  } catch {
    return Response.json({ status: "not-ready" }, { status: 503 });
  }
}
