import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { invokeSubmissionOperation } from "@gurine/api-client-submission";
import {
  operationFields,
  optimisticVersion,
  requiredServerValue,
  serviceAssertionFetch,
} from "@gurine/config";
import {
  canonicalizeScreenViewModel,
  projectFetchedData,
  serverActionDestinations,
  type ScreenRuntime,
  type ScreenViewModel,
  typedScreenViewModel,
} from "@gurine/ui";
import { type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { responseRuntimeState } from "$lib/view-models/runtime";
import {
  ATTACHMENT_ACCEPT,
  ATTACHMENT_MAX_BYTES,
  operations,
} from "./screen-contract";
import {
  actionIdempotencyKeys,
  attachmentItems,
  definedParams,
  formPreset,
  hasOperation,
  isRecord,
  isRedirect,
  loadResponseDraft,
  problemTitle,
  recordProperty,
  sessionKindsForOperation,
  stringProperty,
  withoutToken,
} from "./screen-helpers";
import {
  persistSubmissionSession,
  readSubmissionSession,
} from "./submission-cookie";

export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  screen = canonicalizeScreenViewModel(screen);
  screen = { ...screen, contract: typedScreenViewModel(screen) };
  const data: Record<string, unknown> = {};
  const downloads: Record<
    string,
    { binary: string; mime: string; extension: "json" | "csv" }
  > = {};
  const errors: string[] = [];
  let firstErrorStatus: number | undefined;
  const session = readSubmissionSession(event);
  const attachmentUpload =
    session?.sessionKind === "RESPONSE_ACTIVE" &&
    hasOperation(screen, "createResponseAttachmentUpload") &&
    hasOperation(screen, "finalizeResponseAttachment");
  const hasOneTimeToken = event.url.searchParams.has("token");
  const oneTimeToken = event.url.searchParams.get("token") ?? "";
  const exchangeContract = screen.dataOperations.find(
    (contract) =>
      contract.blocking &&
      contract.method === "POST" &&
      contract.operation_id.startsWith("exchange"),
  );
  if (hasOneTimeToken && !exchangeContract)
    throw redirect(
      303,
      withoutToken(event.url, "보안 링크를 사용할 수 없습니다."),
    );
  if (hasOneTimeToken && exchangeContract) {
    const indexed = operations.get(exchangeContract.operation_id);
    if (!indexed) {
      throw redirect(
        303,
        withoutToken(
          event.url,
          `${exchangeContract.operation_id} 계약을 찾지 못했습니다.`,
        ),
      );
    } else {
      try {
        const result = await invokeSubmissionOperation({
          operationId: exchangeContract.operation_id,
          baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
          fetch: serviceAssertionFetch({
            fetch: event.fetch,
            keyBase64: requiredServerValue(
              env,
              "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
            ),
            issuer: "response-portal",
            audience: "submission-api",
          }),
          body: { oneTimeToken },
          headers: {
            "Idempotency-Key": randomUUID(),
          },
        });
        const response = result.response ?? new Response(null, { status: 503 });
        const value = isRecord(result.data)
          ? result.data
          : isRecord(result.error)
            ? result.error
            : {};
        if (!response.ok) throw new Error(problemTitle(value, response.status));
        const expectedKinds = sessionKindsForOperation(
          exchangeContract.operation_id,
          value,
        );
        if (
          !expectedKinds ||
          !persistSubmissionSession(event, value, expectedKinds)
        )
          throw new Error("교환 응답에 제출 세션이 없습니다.");
        throw redirect(303, withoutToken(event.url));
      } catch (error) {
        if (isRedirect(error)) throw error;
        throw redirect(
          303,
          withoutToken(
            event.url,
            error instanceof Error
              ? error.message
              : "보안 링크 교환에 실패했습니다.",
          ),
        );
      }
    }
  }
  let resolved = 0;
  for (const contract of screen.dataOperations) {
    if (contract.method !== "GET" || !session) continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) continue;
    try {
      const result = await invokeSubmissionOperation({
        operationId: contract.operation_id,
        baseUrl: requiredServerValue(env, "SUBMISSION_API_INTERNAL_URL"),
        fetch: serviceAssertionFetch({
          fetch: event.fetch,
          keyBase64: requiredServerValue(
            env,
            "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
          ),
          issuer: "response-portal",
          audience: "submission-api",
          additionalHeaders: {
            "x-gurine-submission-session": session.opaqueSessionToken,
          },
        }),
        path: definedParams(event.params),
      });
      if (!result.response?.ok) {
        firstErrorStatus ??= result.response?.status ?? 503;
        throw new Error(
          problemTitle(result.error, result.response?.status ?? 503),
        );
      }
      data[contract.operation_id] = result.data;
      if (
        screen.id === "RSP-002" &&
        contract.operation_id === "downloadResponseRequest"
      ) {
        const value = result.data;
        if (isRecord(value) && typeof value.binary === "string") {
          // The submission contract's JSON `format: binary` field is a
          // base64-encoded, server-owned payload at this boundary.
          downloads["download-request"] = {
            binary: value.binary,
            mime: "application/json",
            extension: "json",
          };
        } else if (value instanceof Blob) {
          const bytes = Buffer.from(await value.arrayBuffer());
          downloads["download-request"] = {
            binary: bytes.toString("base64"),
            mime: value.type || "application/octet-stream",
            extension: "json",
          };
        }
      }
      resolved += 1;
    } catch (error) {
      if (contract.blocking)
        errors.push(
          error instanceof Error
            ? error.message
            : `${contract.operation_id} 요청 실패`,
        );
    }
  }
  const requiresResponseDraftVersion = screen.actions.some(
    (action) => stringProperty(action, "operation_id") === "submitResponse",
  );
  const requiresAttachmentList =
    session?.sessionKind === "RESPONSE_ACTIVE" &&
    hasOperation(screen, "deleteResponseAttachment");
  if (
    session &&
    data.getResponseDraft === undefined &&
    ((requiresResponseDraftVersion && optimisticVersion(data) === undefined) ||
      requiresAttachmentList)
  ) {
    try {
      data.getResponseDraft = await loadResponseDraft(
        event,
        session.opaqueSessionToken,
      );
      resolved += 1;
    } catch (error) {
      errors.push(
        error instanceof Error
          ? error.message
          : "최신 답변 초안을 확인하지 못했습니다.",
      );
    }
  }
  const responseDraftVersion = optimisticVersion(data.getResponseDraft);
  const responseDraftVersionUnavailable =
    Boolean(session) &&
    requiresResponseDraftVersion &&
    optimisticVersion(data) === undefined &&
    responseDraftVersion === undefined;
  if (
    responseDraftVersionUnavailable &&
    !errors.includes("최신 답변 초안 version을 확인하지 못했습니다.")
  )
    errors.push("최신 답변 초안 version을 확인하지 못했습니다.");
  const responseAttachments =
    requiresAttachmentList && isRecord(data.getResponseDraft)
      ? attachmentItems(data.getResponseDraft)
      : undefined;
  const blockedActionIds = new Set<string>();
  if (responseDraftVersionUnavailable) blockedActionIds.add("submit");
  if (requiresAttachmentList && responseAttachments === undefined)
    for (const action of screen.actions) {
      if (stringProperty(action, "operation_id") === "deleteResponseAttachment")
        blockedActionIds.add(action.id);
    }
  const routeValues = {
    ...event.params,
    ...(event.url.searchParams.get("token")
      ? { oneTimeToken: event.url.searchParams.get("token") ?? "" }
      : {}),
  };
  const forms = Object.fromEntries(
    screen.actions.map((action) => {
      const operationId = stringProperty(action, "operation_id");
      const indexed = operationId ? operations.get(operationId) : undefined;
      const preset = formPreset(
        data,
        recordProperty(action, "preset"),
        responseDraftVersion,
      );
      return [
        action.id,
        indexed ? operationFields(indexed, routeValues, preset) : [],
      ];
    }),
  );
  const runtime: ScreenRuntime = {
    state:
      firstErrorStatus === 403
        ? "forbidden"
        : firstErrorStatus === 409
          ? "conflict"
          : responseRuntimeState({
              authenticated: Boolean(session),
              errors: errors.length,
              resolved,
            }),
    pathname: event.url.pathname,
    destinations: serverActionDestinations(screen, event.url.pathname),
    ...(session?.csrfToken ? { csrfToken: session.csrfToken } : {}),
    data: {},
    projection: projectFetchedData(screen, data),
    formData: {
      ...(isRecord(data.getResponseDraft)
        ? { responseDraft: data.getResponseDraft }
        : {}),
      ...(isRecord(data.getResponseSubmissionPreview)
        ? { submissionPreview: data.getResponseSubmissionPreview }
        : {}),
    },
    errors,
    forms,
    idempotencyKeys: {
      ...actionIdempotencyKeys(screen),
      ...(attachmentUpload ? { "select-file": randomUUID() } : {}),
    },
    ...(attachmentUpload
      ? {
          attachmentUpload: {
            actionId: "select-file",
            label: "첨부 파일 업로드",
            accept: ATTACHMENT_ACCEPT,
            maxBytes: ATTACHMENT_MAX_BYTES,
          },
        }
      : {}),
    ...(responseAttachments
      ? {
          attachmentRemoval: {
            actionId: "remove-file",
            label: "파일 제거",
            items: responseAttachments,
          },
        }
      : {}),
    ...(Object.keys(downloads).length > 0 ? { downloads } : {}),
    ...(blockedActionIds.size > 0
      ? {
          allowedActionIds: screen.actions
            .filter((action) => !blockedActionIds.has(action.id))
            .map((action) => action.id),
        }
      : {}),
    ...(event.url.searchParams.get("notice")
      ? { notice: event.url.searchParams.get("notice") ?? "" }
      : {}),
  };
  return { screen, runtime };
}
