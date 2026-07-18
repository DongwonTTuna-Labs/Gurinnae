import { createHash } from "node:crypto";
import type { APIRequestContext } from "@playwright/test";

export const mock = "http://127.0.0.1:29100";

export type MockState = {
  submissionExchanges: Array<{
    path: string;
    tokenSha256: string;
    sessionKind: string;
    idempotencyKeySha256: string;
    accepted: boolean;
  }>;
  submissionReads: Array<{ path: string; sessionTokenSha256: string }>;
  submissionWrites: Array<{
    method: string;
    path: string;
    sessionTokenSha256: string;
    bodySha256: string;
    scopeType?: string;
    scopeRef?: string;
  }>;
  attachmentUploads: Array<{
    id: string;
    kind: "correction" | "response";
    sizeBytes: number;
    sha256: string;
    uploaded: boolean;
    finalized: boolean;
  }>;
};

export const sha256 = (value: string) =>
  createHash("sha256").update(value).digest("hex");

export async function state(request: APIRequestContext): Promise<MockState> {
  const response = await request.get(`${mock}/_test/state`);
  if (!response.ok()) throw new Error("mock state endpoint failed");
  return (await response.json()) as MockState;
}
