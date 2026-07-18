import { createHash, randomUUID } from "node:crypto";
import {
  type IndexedOperation,
  operationFields,
  optimisticVersion,
} from "@gurine/config";
import type { ScreenViewModel } from "@gurine/ui";
import type { RequestEvent } from "@sveltejs/kit";
import { readInternalSession } from "./cookies";
import { operations } from "./screen-contract";
export function formsFor(
  screen: ScreenViewModel,
  event: RequestEvent,
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
              }
            : {};
        const preset = {
          ...(expectedVersion !== undefined ? { expectedVersion } : {}),
          ...approvalTarget,
          ...explicit,
        };
        return [
          action.id,
          indexed ? operationFields(indexed, event.params, preset) : [],
        ];
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
export function localActionIds(screen: ScreenViewModel): string[] {
  return screen.actions
    .filter((action) => action.local_only === true)
    .map((action) => action.id);
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
