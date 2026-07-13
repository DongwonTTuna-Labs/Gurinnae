import { env } from "$env/dynamic/private";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async ({ fetch }) => {
  if (!env.SUBMISSION_API_INTERNAL_URL)
    return Response.json({ status: "not-ready" }, { status: 503 });
  try {
    const response = await fetch(
      `${env.SUBMISSION_API_INTERNAL_URL.replace(/\/$/, "")}/health/ready`,
      { signal: AbortSignal.timeout(2_000) },
    );
    return Response.json(
      { status: response.ok ? "ready" : "not-ready" },
      { status: response.ok ? 200 : 503 },
    );
  } catch {
    return Response.json({ status: "not-ready" }, { status: 503 });
  }
};
