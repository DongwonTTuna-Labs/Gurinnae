import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import {
  type IndexedOperation,
  operationFields,
  optimisticVersion,
  type RuntimeField,
} from "@gurine/config";
import type { ScreenViewModel } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { readInternalSession } from "./cookies";
import { isProviderControlOperationId } from "./provider-control-proposal";
import {
  decorateRelayModelFields,
  relayModelActionPreset,
  relayModelFormCaption,
} from "./relay-model-form";
import { operations } from "./screen-contract";

/** Browser forms do not receive a synchronizer token.  The encrypted
 * HttpOnly session cookie plus an explicit same-origin check is the BFF CSRF
 * boundary; the token itself never enters the screen projection or DOM. */
export function sameOrigin(event: RequestEvent): boolean {
  const origin = event.request.headers.get("origin");
  if (origin) return origin === event.url.origin;
  const referer = event.request.headers.get("referer");
  if (!referer) return true;
  try {
    return new URL(referer).origin === event.url.origin;
  } catch {
    return false;
  }
}
export function csrfMatches(
  candidate: FormDataEntryValue | null,
  expected: string,
): boolean {
  if (typeof candidate !== "string") return false;
  const actual = Buffer.from(candidate, "utf8");
  const target = Buffer.from(expected, "utf8");
  return actual.length === target.length && timingSafeEqual(actual, target);
}
export function formsFor(
  screen: ScreenViewModel,
  event: Pick<RequestEvent, "params">,
  data: Record<string, unknown>,
  allowed?: ReadonlySet<string>,
) {
  return Object.fromEntries(
    screen.actions
      .filter((action) => !allowed || allowed.has(action.id))
      .map((action) => {
        const operationId = stringProperty(action, "operation_id");
        const indexed = operationId ? operations.get(operationId) : undefined;
        const explicit = actionPreset(action);
        const expectedVersion = optimisticVersion(data);
        const selectedTarget = recordProperty(data, "selectedTarget");
        const approvalTarget =
          operationId === "submitActionDecision"
            ? {
                ...(typeof selectedTarget.actionKind === "string"
                  ? { actionKind: selectedTarget.actionKind }
                  : {}),
                ...(typeof selectedTarget.proposalId === "string"
                  ? { proposalId: selectedTarget.proposalId }
                  : {}),
                ...(typeof selectedTarget.assignmentId === "string"
                  ? { assignmentId: selectedTarget.assignmentId }
                  : {}),
                ...(typeof selectedTarget.expectedProposalVersion === "number"
                  ? {
                      expectedProposalVersion:
                        selectedTarget.expectedProposalVersion,
                    }
                  : {}),
                ...(typeof selectedTarget.expectedAssignmentVersion === "number"
                  ? {
                      expectedAssignmentVersion:
                        selectedTarget.expectedAssignmentVersion,
                    }
                  : {}),
                ...(typeof selectedTarget.expectedApprovalDigest === "string"
                  ? {
                      expectedApprovalDigest:
                        selectedTarget.expectedApprovalDigest,
                    }
                  : {}),
                ...(selectedTarget.actionKind === "PROVIDER_CONTROL" &&
                typeof selectedTarget.providerOperationId === "string" &&
                isProviderControlOperationId(selectedTarget.providerOperationId)
                  ? {
                      providerOperationId: selectedTarget.providerOperationId,
                    }
                  : {}),
              }
            : {};
        const journeyTarget =
          operationId === "decideJourneyHandoff"
            ? {
                ...(typeof selectedTarget.handoffId === "string"
                  ? { handoffId: selectedTarget.handoffId }
                  : {}),
                ...(typeof selectedTarget.expectedHandoffVersion === "number"
                  ? {
                      expectedHandoffVersion:
                        selectedTarget.expectedHandoffVersion,
                    }
                  : {}),
                ...(typeof selectedTarget.expectedBindingDigest === "string"
                  ? {
                      expectedBindingDigest:
                        selectedTarget.expectedBindingDigest,
                    }
                  : {}),
              }
            : {};
        const relayTarget = relayModelActionPreset(operationId, data);
        const preset = {
          ...(expectedVersion !== undefined ? { expectedVersion } : {}),
          ...approvalTarget,
          ...journeyTarget,
          ...explicit,
          ...relayTarget,
        };
        const fields = indexed
          ? operationFields(
              indexed,
              event.params,
              preset,
              stringArray(action.expand_request_objects),
            )
              .map((field) =>
                operationId === "decideJourneyHandoff" &&
                field.name === "reasonCode"
                  ? {
                      ...field,
                      // The authority request marks reasonCode as nullable but
                      // required: ACKNOWLEDGE sends null, DECLINE sends the
                      // controlled code.  Keep the runtime field optional so
                      // the empty ACK path is serialized as an omitted/null
                      // value instead of being rejected by the generic form
                      // parser before the control API can validate it.
                      required: false,
                      type: "text" as const,
                      options: [
                        "CAPABILITY_UNAVAILABLE",
                        "OBJECT_SCOPE_MISMATCH",
                        "CONFLICT_OF_INTEREST",
                        "WORKLOAD_CAPACITY",
                        "DEPENDENCY_BLOCKED",
                        "SUBJECT_INVALID",
                        "OWNER_UNAVAILABLE",
                        "POLICY_BLOCKED",
                        "RECEIVER_DECLINED",
                      ],
                    }
                  : field,
              )
              .map((field) =>
                operationId === "decideJourneyHandoff" &&
                field.name === "reason"
                  ? { ...field, required: false }
                  : field,
              )
              .flatMap((field) => {
                if (
                  operationId !== "submitActionDecision" ||
                  field.name !== "providerOperationId"
                )
                  return [field];
                const providerOperationId = approvalTarget.providerOperationId;
                return typeof providerOperationId === "string"
                  ? [
                      {
                        ...field,
                        value: providerOperationId,
                        required: true,
                        readonly: true,
                      },
                    ]
                  : [];
              })
          : [];
        return [action.id, decorateRelayModelFields(operationId, fields, data)];
      }),
  );
}

export function formCaptionsFor(
  forms: Readonly<Record<string, readonly RuntimeField[]>>,
  screen: ScreenViewModel,
): Readonly<Record<string, string>> {
  return Object.fromEntries(
    screen.actions.flatMap((action) => {
      const operationId = stringProperty(action, "operation_id");
      const caption = relayModelFormCaption(
        operationId,
        forms[action.id] ?? [],
      );
      return caption ? [[action.id, caption]] : [];
    }),
  );
}

/** Fixed decisions declared by the route contract are server-bound defaults,
 * never caller-editable form fields. `preset` remains for version bindings. */
export function actionPreset(
  action: ScreenViewModel["actions"][number],
): Record<string, unknown> {
  return {
    ...recordProperty(action, "fixed_request"),
    ...recordProperty(action, "preset"),
  };
}
export function isAnonymousProofAction(
  action: ScreenViewModel["actions"][number],
): boolean {
  return (
    stringProperty(action, "operation_id") === "startOidcLogin" &&
    stringProperty(action, "interaction_kind") === "COMMAND" &&
    stringProperty(action, "capability") === "none" &&
    stringProperty(action, "assurance_level") === "ANONYMOUS_PROOF"
  );
}
export function unauthenticatedActionIds(screen: ScreenViewModel): string[] {
  return screen.actions
    .filter(
      (action) => action.local_only === true || isAnonymousProofAction(action),
    )
    .map((action) => action.id);
}
export function safeInternalReturnTo(
  requested: string | null,
  base: URL,
): string {
  const fallback = "/internal/dashboard";
  if (
    !requested?.startsWith("/") ||
    requested.startsWith("//") ||
    requested.includes("\\")
  )
    return fallback;
  const candidate = new URL(requested, base);
  if (
    candidate.origin !== base.origin ||
    (candidate.pathname !== "/internal" &&
      !candidate.pathname.startsWith("/internal/"))
  )
    return fallback;
  return `${candidate.pathname}${candidate.search}${candidate.hash}`;
}
export function actionIdempotencyKeys(
  screen: ScreenViewModel,
  allowed: ReadonlySet<string>,
): Readonly<Record<string, string>> {
  return Object.fromEntries(
    screen.actions
      .filter(
        (action) =>
          allowed.has(action.id) && stringProperty(action, "operation_id"),
      )
      .map((action) => [action.id, randomUUID()]),
  );
}
export function formIdempotencyKey(form: FormData): string {
  const value = form.get("idempotencyKey");
  if (
    typeof value !== "string" ||
    value.length < 8 ||
    value.length > 200 ||
    !/^[\x20-\x7e]+$/.test(value)
  )
    throw new Error("멱등성 키가 없거나 올바르지 않습니다.");
  return value;
}
export function actionAllowed(
  action: ScreenViewModel["actions"][number],
  capabilities: readonly string[],
): boolean {
  const capability = stringProperty(action, "capability");
  return (
    action.local_only === true ||
    !capability ||
    capability === "none" ||
    capabilities.includes(capability)
  );
}
export function recordValue(
  value: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const item = value[key];
  return isRecord(item) ? item : {};
}

export function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}
export function operationQuery(
  parameters: Array<{ name: string; in: string; required?: boolean }>,
  current: URLSearchParams,
): string | null {
  const query = new URLSearchParams();
  for (const parameter of parameters.filter((item) => item.in === "query")) {
    const values = current.getAll(parameter.name);
    if (parameter.required && values.length === 0) return null;
    for (const value of values) query.append(parameter.name, value);
  }
  return query.toString();
}
export function queryRecord(rawQuery: string): Record<string, unknown> {
  const output: Record<string, unknown> = {};
  const query = new URLSearchParams(rawQuery);
  for (const key of new Set(query.keys())) {
    const values = query.getAll(key);
    output[key] = values.length === 1 ? values[0] : values;
  }
  return output;
}
export function queryString(value: Record<string, unknown>): string {
  const query = new URLSearchParams();
  for (const [name, item] of Object.entries(value)) {
    if (Array.isArray(item)) {
      for (const entry of item) query.append(name, String(entry));
    } else if (item !== undefined && item !== null) {
      query.append(
        name,
        typeof item === "object" ? JSON.stringify(item) : String(item),
      );
    }
  }
  return query.toString();
}
export function bindRouteValues(
  value: Record<string, unknown>,
  params: Record<string, string | undefined>,
): Record<string, unknown> {
  const output = { ...value };
  for (const [name, item] of Object.entries(params)) {
    if (item !== undefined && name in output) output[name] = item;
  }
  return output;
}
export function definedParams(
  params: Record<string, string | undefined>,
): Record<string, string> {
  return Object.fromEntries(
    Object.entries(params).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );
}
export function sessionToken(event: RequestEvent): string | undefined {
  return readInternalSession(event)?.opaqueIdentitySessionToken;
}
export function csrf(event: RequestEvent): string | undefined {
  return readInternalSession(event)?.csrfToken;
}
export function aggregateType(operationId: string): string {
  return (
    operationId
      .replaceAll(/([a-z0-9])([A-Z])/g, "$1_$2")
      .split("_")
      .at(-1)
      ?.toLowerCase() ?? "control"
  );
}
export function findAggregateId(
  body: Record<string, unknown>,
  params: Record<string, string | undefined>,
): string {
  for (const [key, value] of [
    ...Object.entries(body),
    ...Object.entries(params),
  ])
    if (key.endsWith("Id") && typeof value === "string") return value;
  return randomUUID();
}
export function renderRoute(
  route: string,
  params: Record<string, string | undefined>,
): string {
  return route.replaceAll(
    /\{([^}]+)\}/g,
    (_, key: string) => params[key] ?? "",
  );
}
export function normalize(
  value: Record<string, unknown>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key.replaceAll(/_([a-z])/g, (_, letter: string) => letter.toUpperCase()),
      item,
    ]),
  );
}
export function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
export function epochSeconds(value: string): number {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds))
    throw new Error("invalid expiry timestamp");
  return Math.floor(milliseconds / 1000);
}
export function stringValue(
  value: Record<string, unknown>,
  key: string,
): string {
  const item = value[key];
  if (typeof item !== "string") throw new Error(`${key} is missing`);
  return item;
}
export function problemTitle(value: unknown, status: number): string {
  return isRecord(value) && typeof value.title === "string"
    ? value.title
    : `요청 실패 (${status})`;
}
export function stringExtension(
  indexed: IndexedOperation,
  key: `x-${string}`,
): string | undefined {
  const value = indexed.operation[key];
  return typeof value === "string" ? value : undefined;
}
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function stringProperty(
  value: Record<string, unknown>,
  key: string,
): string | undefined {
  const item = value[key];
  return typeof item === "string" ? item : undefined;
}
export function recordProperty(
  value: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const item = value[key];
  return isRecord(item) ? item : {};
}
export function isRedirect(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.status === "number" &&
    value.status >= 300 &&
    value.status < 400
  );
}
