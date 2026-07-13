import { env } from "$env/dynamic/private";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async ({ fetch }) => {
  const dependencies = [
    env.CONTROL_API_INTERNAL_URL,
    env.IDENTITY_API_INTERNAL_URL,
  ];
  if (dependencies.some((value) => !value))
    return Response.json({ status: "not-ready" }, { status: 503 });
  try {
    const responses = await Promise.all(
      dependencies.map((base) =>
        fetch(`${base?.replace(/\/$/, "")}/health/ready`, {
          signal: AbortSignal.timeout(2_000),
        }),
      ),
    );
    const ready = responses.every((response) => response.ok);
    return Response.json(
      { status: ready ? "ready" : "not-ready" },
      { status: ready ? 200 : 503 },
    );
  } catch {
    return Response.json({ status: "not-ready" }, { status: 503 });
  }
};
