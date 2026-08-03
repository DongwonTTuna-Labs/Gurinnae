import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { invokePublicOperation } from "@gurine/api-client-public";
import { operationFields, requiredServerValue } from "@gurine/config";
import {
  buildRowSelectionNavigationOptions,
  canonicalizeScreenViewModel,
  PUBLIC_LEDGER_CONTRACTS,
  projectFetchedData,
  type ScreenField,
  type ScreenRuntime,
  type ScreenViewModel,
  typedScreenViewModel,
} from "@gurine/ui";
import { type RequestEvent, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { publicRuntimeState } from "$lib/view-models/runtime";
import { publicCasePresentation } from "./public-case-presentation";
import { verifiedPublicDownloadPayload } from "./public-export";
import { publicFundingPresentation } from "./public-funding-presentation";
import {
  publicDatasetPresentation,
  publicFailClosedLedgerPresentation,
  publicLedgerPresentation,
} from "./public-presentation";
import {
  publicFailClosedSeoPresentation,
  publicSeoPresentation,
} from "./public-seo-presentation";
import { publicStatusPresentation } from "./public-status-presentation";
import {
  operationPathParams,
  operationQuery,
  submissionLoadRequest,
  submissionRequest,
} from "./screen-actions";
import {
  ATTACHMENT_ACCEPT,
  ATTACHMENT_MAX_BYTES,
  operations,
} from "./screen-contract";
import { publicScreenDestinations } from "./screen-destinations";
import {
  actionIdempotencyKeys,
  actionOperationId,
  actionPreset,
  attachmentItems,
  correctionBootstrapFields,
  correctionBootstrapRequired,
  formPreset,
  hasOperation,
  hasRecords,
  isRecord,
  isRedirect,
  mergeFields,
  problemTitle,
  sessionKindsForOperation,
  tokenBody,
  tokenDestination,
  withoutToken,
} from "./screen-helpers";
import {
  persistSubmissionSession,
  readSubmissionSession,
} from "./submission-cookie";

export { publicScreenDestinations };

export const INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE =
  "필수 검색 조건이 올바르지 않습니다.";
export const PUBLIC_FUNDING_TEST_FIXTURE_QUERY = "__testFixture";
export const PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE =
  "FUNDING_LIST_UNAVAILABLE";

type PublicInitialLoadPlan =
  | { kind: "request"; query: Record<string, unknown> }
  | { kind: "skip"; state: "awaiting-query" }
  | { kind: "invalid" };

export function publicInitialLoadPlan(
  screenId: string,
  operationId: string,
  parameters: Array<{ name: string; in: string; required?: boolean }>,
  current: URLSearchParams,
): PublicInitialLoadPlan {
  if (
    screenId === "PUB-002" &&
    operationId === "searchPublicRecords" &&
    !current.get("q")?.trim()
  ) {
    return { kind: "skip", state: "awaiting-query" };
  }
  const query = operationQuery(parameters, current);
  if (query === null) return { kind: "invalid" };
  if (
    screenId === "PUB-001" &&
    operationId === "listPublicCases" &&
    query.sort === undefined
  ) {
    return { kind: "request", query: { ...query, sort: "published_desc" } };
  }
  return { kind: "request", query };
}

function publicFundingFixtureQuery(
  screenId: string,
  operationId: string,
  current: URLSearchParams,
  query: Record<string, unknown>,
): Record<string, unknown> {
  const selector = current.getAll(PUBLIC_FUNDING_TEST_FIXTURE_QUERY);
  if (
    env.GURINE_ENV !== "test" ||
    screenId !== "PUB-023" ||
    operationId !== "listTransparencyReports" ||
    selector.length !== 1 ||
    selector[0] !== PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE
  ) {
    return query;
  }
  return {
    ...query,
    [PUBLIC_FUNDING_TEST_FIXTURE_QUERY]:
      PUBLIC_FUNDING_LIST_UNAVAILABLE_FIXTURE,
  };
}

export async function loadScreen(event: RequestEvent, screen: ScreenViewModel) {
  screen = canonicalizeScreenViewModel(screen);
  screen = { ...screen, contract: typedScreenViewModel(screen) };
  const data: Record<string, unknown> = {};
  const downloads: Record<
    string,
    { binary: string; mime: string; extension: "json" | "csv" | "jsonl" }
  > = {};
  const errors: string[] = [];
  let neutralInitialState: "awaiting-query" | undefined;
  const submissionSession = readSubmissionSession(event);
  const attachmentUpload =
    submissionSession?.sessionKind === "CORRECTION_DRAFT" &&
    hasOperation(screen, "createCorrectionAttachment") &&
    hasOperation(screen, "finalizeCorrectionAttachment");
  const bootstrapCorrection = correctionBootstrapRequired(
    screen,
    submissionSession,
  );
  const hasOneTimeToken = event.url.searchParams.has("token");
  const oneTimeToken = event.url.searchParams.get("token") ?? "";
  const tokenContract = screen.dataOperations.find(
    (contract) =>
      contract.blocking &&
      contract.method === "POST" &&
      (contract.operation_id.startsWith("exchange") ||
        contract.operation_id === "verifySubscription"),
  );
  if (hasOneTimeToken && !tokenContract)
    throw redirect(
      303,
      withoutToken(event.url, "보안 링크를 사용할 수 없습니다."),
    );
  if (hasOneTimeToken && tokenContract) {
    try {
      const { response, value } = await submissionRequest(
        event,
        tokenContract.operation_id,
        tokenBody(tokenContract.operation_id, oneTimeToken),
        undefined,
        randomUUID(),
      );
      if (!response.ok) throw new Error(problemTitle(value, response.status));
      const expectedKinds = sessionKindsForOperation(
        tokenContract.operation_id,
      );
      if (
        !expectedKinds ||
        !persistSubmissionSession(event, value, expectedKinds)
      )
        throw new Error("교환 응답에 제출 세션이 없습니다.");
      throw redirect(
        303,
        tokenDestination(event.url, tokenContract.operation_id),
      );
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
  let resolved = 0;
  let fundingReportListUnavailable = false;
  for (const contract of screen.dataOperations) {
    if (screen.id === "PUB-035" && contract.api === "billing-gateway-private")
      continue;
    if (contract.method !== "GET") continue;
    if (bootstrapCorrection && contract.api === "submission-api") continue;
    if (
      !contract.blocking &&
      contract.operation_id.startsWith("download") &&
      !(
        screen.id === "PUB-011" && contract.operation_id === "downloadContracts"
      )
    )
      continue;
    const indexed = operations.get(contract.operation_id);
    if (!indexed) {
      if (contract.blocking)
        errors.push(`${contract.operation_id} 계약을 찾지 못했습니다.`);
      continue;
    }
    try {
      let plan = publicInitialLoadPlan(
        screen.id,
        contract.operation_id,
        indexed.operation.parameters ?? [],
        event.url.searchParams,
      );
      // PUB-011's download action is local-only by contract, while its
      // server operation returns the export receipt that must be bound to the
      // browser download.  The format is intentionally fixed here so the
      // initial screen can prepare a deterministic JSON receipt without
      // exposing the public API's internal URL or raw response DTO.
      if (
        plan.kind === "invalid" &&
        screen.id === "PUB-011" &&
        contract.operation_id === "downloadContracts"
      ) {
        const optionalFormatParameters = (
          indexed.operation.parameters ?? []
        ).map((parameter) =>
          parameter.name === "format"
            ? { ...parameter, required: false }
            : parameter,
        );
        plan = {
          kind: "request",
          query: {
            ...(operationQuery(
              optionalFormatParameters,
              event.url.searchParams,
            ) ?? {}),
            format: "JSONL",
          },
        };
      }
      if (plan.kind === "skip") {
        neutralInitialState = plan.state;
        continue;
      }
      if (plan.kind === "invalid") {
        if (contract.blocking) {
          errors.push(INVALID_REQUIRED_SEARCH_CONDITIONS_MESSAGE);
        }
        continue;
      }
      const query = publicFundingFixtureQuery(
        screen.id,
        contract.operation_id,
        event.url.searchParams,
        plan.query,
      );
      const result =
        contract.api === "submission-api"
          ? await submissionLoadRequest(
              event,
              contract.operation_id,
              indexed.path,
              query,
              submissionSession,
            )
          : await invokePublicOperation({
              operationId: contract.operation_id,
              baseUrl: requiredServerValue(env, "PUBLIC_API_INTERNAL_URL"),
              fetch: event.fetch,
              path: operationPathParams(indexed.path, event.params),
              query,
            });
      if (!result.response?.ok)
        throw new Error(
          problemTitle(result.error, result.response?.status ?? 503),
        );
      data[contract.operation_id] = result.data;
      if (
        screen.id === "PUB-011" &&
        contract.operation_id === "downloadContracts"
      ) {
        const expectedFilters = publicDownloadFilters(query);
        if (!expectedFilters)
          throw new Error("계약 내려받기 조건을 검증하지 못했습니다.");
        const payload = verifiedPublicDownloadPayload(result.data, {
          format: "JSONL",
          kind: "CONTRACTS",
          expectedFilters,
        });
        if (!payload)
          throw new Error("계약 내려받기 파일 무결성을 확인하지 못했습니다.");
        if (
          !isRecord(result.data) ||
          typeof result.data.id !== "string" ||
          result.data.status !== "READY" ||
          typeof result.data.version !== "number"
        )
          throw new Error("계약 내려받기 영수증을 확인하지 못했습니다.");
        const receipt = {
          id: result.data.id,
          status: result.data.status,
          version: result.data.version,
          format: "JSONL" as const,
        };
        downloads.download = {
          binary: Buffer.from(`${JSON.stringify(receipt)}\n`, "utf8").toString(
            "base64",
          ),
          mime: "application/json",
          extension: "json",
        };
      }
      resolved += 1;
    } catch (error) {
      if (
        screen.id === "PUB-023" &&
        contract.operation_id === "listTransparencyReports"
      ) {
        fundingReportListUnavailable = true;
      }
      if (contract.blocking)
        errors.push(
          error instanceof Error
            ? error.message
            : `${contract.operation_id} 요청 실패`,
        );
    }
  }
  const correctionAttachments =
    submissionSession?.sessionKind === "CORRECTION_DRAFT" &&
    hasOperation(screen, "deleteCorrectionAttachment") &&
    isRecord(data.getCorrectionRequestDraftPreview)
      ? attachmentItems(data.getCorrectionRequestDraftPreview)
      : undefined;
  const forms: Record<string, readonly ScreenField[]> = Object.fromEntries(
    screen.actions.map((action) => {
      const operationId = actionOperationId(screen, action);
      const indexed = operationId ? operations.get(operationId) : undefined;
      const preset = formPreset(data, actionPreset(event, screen, action));
      const fields = indexed
        ? operationFields(indexed, event.params, preset)
        : [];
      return [
        action.id,
        bootstrapCorrection && operationId === "saveCorrectionRequestDraft"
          ? mergeFields(correctionBootstrapFields(event), fields)
          : fields,
      ];
    }),
  );
  const needsBotChallenge = Object.values(forms).some((fields) =>
    fields.some((field) => field.name === "abuseProof"),
  );
  const siteKey = env.BOT_CHALLENGE_SITE_KEY?.trim();
  if (needsBotChallenge && !siteKey)
    errors.push("자동 제출 방지 검증이 구성되지 않았습니다.");
  const hasData = Object.values(data).some((value) => hasRecords(value));
  let ledgerPresentation: ReturnType<typeof publicLedgerPresentation>;
  let publicDatasets: ReturnType<typeof publicDatasetPresentation>;
  let publicCase: ReturnType<typeof publicCasePresentation>;
  let publicSeo: ReturnType<typeof publicSeoPresentation>;
  let publicStatus: ReturnType<typeof publicStatusPresentation>;
  let fundingTransparency: ReturnType<typeof publicFundingPresentation>;
  let presentationFailed = false;
  try {
    ledgerPresentation = publicLedgerPresentation(screen.id, data);
    publicDatasets = publicDatasetPresentation(screen.id, data);
    publicCase = publicCasePresentation(screen.id, data, event.url);
    publicStatus = publicStatusPresentation(screen.id, data);
    fundingTransparency = publicFundingPresentation(screen.id, data);
    publicSeo = publicSeoPresentation(screen.id, screen.title, data, event.url);
  } catch {
    presentationFailed = true;
    ledgerPresentation = publicFailClosedLedgerPresentation(screen.id);
    publicDatasets = undefined;
    publicCase = undefined;
    publicSeo = publicFailClosedSeoPresentation(
      screen.id,
      screen.title,
      event.url,
    );
    publicStatus = undefined;
    fundingTransparency = undefined;
    errors.push(
      screen.id === "PUB-004"
        ? "공개 사건 응답 형식이 올바르지 않습니다."
        : screen.id === "PUB-020"
          ? "공개 데이터셋 응답 형식이 올바르지 않습니다."
          : "공개 목록 응답 형식이 올바르지 않습니다.",
    );
  }
  const projectionData = presentationFailed ? {} : data;
  const navigationOptions = presentationFailed
    ? {}
    : (ledgerPresentation?.navigationOptions ??
      (Object.hasOwn(PUBLIC_LEDGER_CONTRACTS, screen.id)
        ? {}
        : buildRowSelectionNavigationOptions(screen.id, projectionData)));
  const destinations = {
    ...publicScreenDestinations(
      screen,
      event.url.pathname,
      projectionData,
      event.url.searchParams,
    ),
    ...(fundingTransparency?.reports[0]
      ? {
          "download-report": fundingTransparency.reports[0].jsonDownloadHref,
        }
      : {}),
  };
  const runtime: ScreenRuntime = {
    state: presentationFailed
      ? "error"
      : fundingReportListUnavailable && fundingTransparency
        ? "partial"
        : neutralInitialState && errors.length === 0 && resolved === 0
          ? neutralInitialState
          : publicRuntimeState({
              errors: errors.length,
              resolved,
              hasData,
              invalidFilter: errors.some((error) =>
                error.includes("필수 검색 조건"),
              ),
            }),
    pathname: event.url.pathname,
    data: {},
    projection: projectFetchedData(screen, projectionData),
    errors,
    forms,
    ...(ledgerPresentation
      ? { publicLedger: ledgerPresentation.viewModel }
      : {}),
    ...(publicDatasets !== undefined ? { publicDatasets } : {}),
    ...(publicCase
      ? {
          publicCaseLead: publicCase.lead,
          publicEvidence: publicCase.evidence,
        }
      : {}),
    ...(publicSeo ? { publicSeo } : {}),
    ...(publicStatus ? { publicStatusContext: publicStatus } : {}),
    ...(fundingTransparency ? { fundingTransparency } : {}),
    ...(screen.id === "PUB-020"
      ? { formOperationIds: { "download-dataset": "createDatasetExport" } }
      : {}),
    ...(!presentationFailed && Object.keys(downloads).length > 0
      ? { downloads }
      : {}),
    idempotencyKeys: {
      ...actionIdempotencyKeys(screen),
      ...(attachmentUpload ? { "upload-attachment": randomUUID() } : {}),
      ...(correctionAttachments ? { "remove-attachment": randomUUID() } : {}),
    },
    ...(needsBotChallenge && siteKey
      ? {
          botChallenge: {
            provider:
              siteKey === "synthetic-test" ? "SYNTHETIC_TEST" : "TURNSTILE",
            siteKey,
          } as const,
        }
      : {}),
    ...(attachmentUpload
      ? {
          attachmentUpload: {
            actionId: "upload-attachment",
            label: "근거 파일 업로드",
            accept: ATTACHMENT_ACCEPT,
            maxBytes: ATTACHMENT_MAX_BYTES,
          },
        }
      : {}),
    ...(correctionAttachments
      ? {
          attachmentRemoval: {
            actionId: "remove-attachment",
            label: "첨부 파일 제거",
            items: correctionAttachments,
          },
        }
      : {}),
    ...(bootstrapCorrection ? { allowedActionIds: ["save-draft"] } : {}),
    ...(event.url.searchParams.get("notice")
      ? { notice: event.url.searchParams.get("notice") ?? "" }
      : {}),
    search: event.url.search,
    destinations,
    ...(Object.keys(navigationOptions).length > 0 ? { navigationOptions } : {}),
  };
  return { screen, runtime };
}

function publicDownloadFilters(
  query: Readonly<Record<string, unknown>>,
): Readonly<Record<string, string | boolean | readonly string[]>> | undefined {
  const filters: Record<string, string | boolean | readonly string[]> = {};
  for (const [name, value] of Object.entries(query)) {
    if (name === "format") continue;
    if (typeof value === "string" || typeof value === "boolean") {
      filters[name] = value;
    } else if (
      Array.isArray(value) &&
      value.every((item) => typeof item === "string")
    ) {
      filters[name] = value;
    } else {
      return;
    }
  }
  return filters;
}
