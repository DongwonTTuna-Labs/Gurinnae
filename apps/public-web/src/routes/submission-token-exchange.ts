import { randomUUID } from "node:crypto";
import type { SubmissionSessionKind } from "@gurine/config";
import type { RequestEvent } from "@sveltejs/kit";
import { submissionRequest } from "$lib/server/screen-actions";
import { problemTitle } from "$lib/server/screen-helpers";
import { persistSubmissionSession } from "$lib/server/submission-cookie";

interface SubmissionTokenExchangeContract {
  operationId:
    | "exchangeCorrectionReceiptToken"
    | "exchangeSubscriptionManagementToken";
  canonicalPath: "/correction-request/receipt" | "/subscription/manage";
  sessionKind: SubmissionSessionKind;
}

export async function exchangeSubmissionToken(
  event: RequestEvent,
  contract: SubmissionTokenExchangeContract,
): Promise<Response> {
  const tokens = event.url.searchParams.getAll("token");
  if (tokens.length !== 1 || !tokens[0])
    return canonicalRedirect(
      contract.canonicalPath,
      "보안 링크를 사용할 수 없습니다.",
    );

  try {
    const { response, value } = await submissionRequest(
      event,
      contract.operationId,
      { oneTimeToken: tokens[0] },
      "",
      randomUUID(),
    );
    if (!response.ok)
      return canonicalRedirect(
        contract.canonicalPath,
        problemTitle(value, response.status),
      );
    if (!persistSubmissionSession(event, value, [contract.sessionKind]))
      return canonicalRedirect(
        contract.canonicalPath,
        "교환 응답에 제출 세션이 없습니다.",
      );
    return canonicalRedirect(contract.canonicalPath);
  } catch {
    return canonicalRedirect(
      contract.canonicalPath,
      "보안 링크 교환에 실패했습니다.",
    );
  }
}

function canonicalRedirect(path: string, notice?: string): Response {
  const search = notice ? `?${new URLSearchParams({ notice }).toString()}` : "";
  return new Response(null, {
    status: 303,
    headers: {
      "cache-control": "no-store",
      location: `${path}${search}`,
      "referrer-policy": "no-referrer",
    },
  });
}
