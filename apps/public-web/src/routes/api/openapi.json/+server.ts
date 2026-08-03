import { invokePublicOperation } from "@gurine/api-client-public";
import { requiredServerValue } from "@gurine/config";
import { env } from "$env/dynamic/private";
import type { RequestHandler } from "./$types";

export const GET: RequestHandler = async ({ fetch }) => {
  const result = await invokePublicOperation({
    operationId: "downloadPublicOpenApi",
    baseUrl: requiredServerValue(env, "PUBLIC_API_INTERNAL_URL"),
    fetch,
  });
  if (!result.response?.ok) {
    return new Response(null, {
      status: result.response?.status ?? 503,
      headers: { "cache-control": "no-store" },
    });
  }
  return new Response(JSON.stringify(result.data, null, 2), {
    headers: {
      "cache-control": "public, max-age=300",
      "content-disposition":
        'attachment; filename="gurine-public-api.openapi.json"',
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
};
