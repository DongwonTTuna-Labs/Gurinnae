import { createHash, randomUUID } from "node:crypto";
import type { RequestEvent } from "@sveltejs/kit";

export function requestContext(event: RequestEvent) {
  let address = "unavailable";
  try {
    address = event.getClientAddress();
  } catch {
    // Some test adapters intentionally do not expose the peer address.
  }
  return {
    ipHash: digest(address),
    userAgentHash: digest(
      event.request.headers.get("user-agent") ?? "unavailable",
    ),
    requestId: randomUUID(),
  };
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
