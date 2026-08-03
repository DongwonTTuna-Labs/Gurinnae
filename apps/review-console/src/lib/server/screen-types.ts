export type PendingAction = {
  operationId: string;
  path: string;
  body: Record<string, unknown>;
  bodyBytes: string;
  idempotencyKey: string;
  actionContext: Record<string, unknown>;
  returnTo: string;
  pathParams: Record<string, string>;
  requiredAssuranceLevel?: "ACTIVE_SESSION" | "STEP_UP";
};

export type ElevatedAuthorization = {
  actionDigest: string;
  stepUpAuthorizationToken: string;
  idempotencyKeySha256: string;
  csrfToken: string;
};
