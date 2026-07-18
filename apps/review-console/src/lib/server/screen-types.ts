export type PendingAction = {
  operationId: string;
  path: string;
  body: Record<string, unknown>;
  bodyBytes: string;
  idempotencyKey: string;
  actionContext: Record<string, unknown>;
  returnTo: string;
  pathParams: Record<string, string>;
};

export type ElevatedAuthorization = {
  actionDigest: string;
  stepUpAuthorizationToken: string;
  idempotencyKeySha256: string;
  csrfToken: string;
};
