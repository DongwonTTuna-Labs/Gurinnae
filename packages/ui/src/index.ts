export { default as ScreenPage } from "./components/ScreenPage.svelte";
export * from "./decision-contract";
export * from "./donation";
export * from "./enum-presentation";
export * from "./funding-transparency";
export * from "./generated-screen-journeys";
export * from "./local-actions";
export * from "./projection-value";
export * from "./public-action-placement";
export * from "./public-case-presentation";
export * from "./public-corrections";
export type {
  CorrectionRequestFormContract,
  DatasetExportFormat,
  DatasetExportFormContract,
  PublicDatasetCard,
  PublicDatasetRecord,
} from "./public-form-presentation";
export {
  correctionRequestFormContract,
  DATASET_EXPORT_FORMATS,
  datasetExportFormContract,
  hiddenFieldValue,
  namedFormAction as publicFormAction,
  publicDatasetCards,
  requestedChangesJson,
  requestedChangesText,
} from "./public-form-presentation";
export * from "./public-ledger";
export * from "./public-status-notice";
export * from "./related-public-cases";
export * from "./relay-model-catalog";
export * from "./retention-schedule";
export * from "./row-selection-navigation";
export * from "./screen-archetype";
export * from "./screen-chrome";
export * from "./screen-contract";
export * from "./screen-projection";
export * from "./server-destinations";
export * from "./subscription-form";
export * from "./tokens";
export * from "./url-filter-contracts";
export * from "./view-models/cas-010";
export * from "./view-models/cas-011";
export * from "./view-models/int-002";
export * from "./view-models/ops-004";
export * from "./view-models/rsp-003";
export * from "./view-models/rsp-005";
export * from "./view-models/rsp-006";

export type ScreenSection = ScreenViewModel["sections"][number];
export type ScreenSectionProps = {
  section: ScreenSection;
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  index: number;
  /** Typed, display-safe section projection. Components must not read raw DTOs. */
  projection?:
    | import("./screen-projection").ScreenSectionProjection
    | undefined;
};

export type ScreenField = {
  name: string;
  label: string;
  type: "text" | "number" | "boolean" | "date" | "datetime-local" | "json";
  required: boolean;
  options?: readonly string[];
  value?: string | number | boolean;
  readonly?: boolean;
  payloadPath?: readonly [string, string];
  challengeAction?: string;
};

export type BotChallengeRuntime = {
  provider: "TURNSTILE" | "SYNTHETIC_TEST";
  siteKey: string;
};

export type AttachmentUploadRuntime = {
  actionId: string;
  label: string;
  accept: string;
  maxBytes: number;
};

export type AttachmentRemovalItem = {
  id: string;
  filename: string;
  mediaType?: string;
  sizeBytes?: number;
  uploadStatus?: string;
  scanStatus?: string;
};

export type AttachmentRemovalRuntime = {
  actionId: string;
  label: string;
  items: readonly AttachmentRemovalItem[];
};

export type ScreenRuntime = {
  state:
    | "loading"
    | "awaiting-query"
    | "initial-loading"
    | "success"
    | "empty"
    | "filtered-empty"
    | "partial"
    | "stale"
    | "error"
    | "server-error"
    | "not-found"
    | "unauthenticated"
    | "unauthorized"
    | "forbidden"
    | "conflict"
    | "receipt"
    | "offline"
    | "saving"
    | "saved"
    | "current"
    | "draft"
    | "superseded"
    | "healthy"
    | "maintenance"
    | "invalid-filter"
    | "validation-error"
    | "session-expiring"
    | "session-expired"
    | "blocked"
    | "refreshing"
    | "degraded"
    | "incident"
    | "telemetry-gap"
    | "ready"
    | "reauth-required"
    | "submitting"
    | "partial-failure"
    | "terminal";
  data: Record<string, unknown>;
  /**
   * Server-owned, display-safe data envelope.  Components and projections
   * must consume this allowlisted shape instead of operation response DTOs.
   * Missing values remain explicit UNKNOWN entries so SSR never guesses from
   * arbitrary runtime JSON.
   */
  projection?: ScreenRuntimeProjection;
  errors: readonly string[];
  forms: Record<string, readonly ScreenField[]>;
  /** Concise action-form captions selected at the server-owned form boundary. */
  formCaptions?: Readonly<Record<string, string>>;
  formOperationIds?: Readonly<Record<string, string>>;
  idempotencyKeys?: Readonly<Record<string, string>>;
  botChallenge?: BotChallengeRuntime;
  /** SSR synchronizer token echoed by every mutating form. */
  csrfToken?: string;
  attachmentUpload?: AttachmentUploadRuntime;
  attachmentRemoval?: AttachmentRemovalRuntime;
  notice?: string;
  pathname?: string;
  /** Current URL query, retained when a named form action posts back. */
  search?: string;
  allowedActionIds?: readonly string[];
  actorDisplayName?: string;
  sessionExpiresAt?: string;
  /** Server-validated approval binding; never inferred from arbitrary DTO data. */
  selectedTarget?: {
    proposalId: string;
    actionKind: string | null;
    assignmentId: string | null;
    expectedProposalVersion: number;
    expectedAssignmentVersion: number | null;
    expectedApprovalDigest: string;
    handoffId: string | null;
    expectedHandoffVersion: number | null;
    expectedBindingDigest: string | null;
    digestCurrent: boolean;
    loadState: "READY" | "BLOCKED";
  };
  /**
   * Server-validated approval queue cards.  This is deliberately narrower
   * than the action-proposal DTO: the browser receives only the identifiers,
   * version/digest binding and a server-owned navigation target needed to
   * choose a proposal.  Components must not scan runtime.data for queue rows.
   */
  approvalQueue?: readonly {
    proposalId: string;
    version: number;
    state: string;
    approvalDigest: string;
    href: string;
  }[];
  /** Action-scoped, server-validated row destinations exposed as label + href only. */
  navigationOptions?: import("./row-selection-navigation").RowSelectionNavigationOptions;
  /** Closed OPS-005 model/provider ledger; raw relay DTOs remain server-only. */
  relayModelCatalog?: import("./relay-model-catalog").RelayModelCatalogViewModel;
  /** Closed public ledger rows prepared at the server boundary. */
  publicLedger?: import("./public-ledger").PublicLedgerViewModel;
  /** Closed public dataset cards prepared at the server boundary. */
  publicDatasets?: readonly import("./public-form-presentation").PublicDatasetRecord[];
  /** Closed PUB-004 lead. The operation DTO remains server-only. */
  publicCaseLead?: import("./public-case-presentation").PublicCaseLeadViewModel;
  /** Closed PUB-004 evidence metadata without protected evidence fields. */
  publicEvidence?: readonly import("./public-case-presentation").PublicEvidenceViewModel[];
  /** Closed legal context kept adjacent to an applicable public status. */
  publicStatusContext?: import("./public-status-notice").PublicDetailStatusContext;
  /** Same-origin public metadata validated at the public server boundary. */
  publicSeo?: import("./public-case-presentation").PublicSeoViewModel;
  /** Closed /privacy status projection; receipt identifiers and digests remain server-only. */
  privacyRequestStatus?:
    | Readonly<{
        loadState: "UNAVAILABLE";
      }>
    | Readonly<{
        loadState: "READY";
        requestType: "ACCESS" | "CORRECTION" | "DELETION" | "RESTRICTION";
        state: "RECEIVED" | "REVIEW" | "APPROVED" | "REJECTED" | "COMPLETED";
        identityState: "PENDING_VERIFICATION" | "VERIFIED";
        identityVerifiedAt: string | null;
        dueAt: string | null;
        updatedAt: string;
        nextActionCode:
          | "VERIFY_IDENTITY"
          | "AWAIT_REVIEW"
          | "AWAIT_DECISION"
          | "AWAIT_EXECUTION"
          | "REVIEW_REFUSAL_NOTICE"
          | "COMPLETE";
        asOf: string;
      }>;
  /** Closed PUB-035 test-only offer and queue receipt projection. */
  donation?: import("./donation").DonationScreenRuntime;
  /** Closed PUB-023 approved disclosure and report download projection. */
  fundingTransparency?: import("./funding-transparency").FundingTransparencyViewModel;
  /** Server-owned navigation destinations. Raw DTO traversal is forbidden. */
  destinations?: Readonly<Record<string, string>>;
  /** Server-prepared, action-scoped binary exports; raw DTOs never reach download code. */
  downloads?: Readonly<
    Record<
      string,
      { binary: string; mime: string; extension: "json" | "csv" | "jsonl" }
    >
  >;
  /** Narrow, server-owned form context for progressive response editing. */
  formData?: {
    responseDraft?: Record<string, unknown>;
    submissionPreview?: Record<string, unknown>;
    submitted?: Record<string, unknown>;
  };
};

export type ScreenProjectionScalar = string | number | boolean;
export type ScreenProjectionValue =
  import("./projection-value").ProjectionValue;

export type ScreenRuntimeProjectionField = {
  /** Contextual content heading supplied by a closed specialized mapper. */
  contextualLabel?: string;
  value: ScreenProjectionValue | null;
  known: boolean;
  source: string;
};

export type ScreenRuntimeProjectionSection = {
  fields: Readonly<Record<string, ScreenRuntimeProjectionField>>;
  blocked: boolean;
  /** Optional server-owned analysis metadata retained for accessible CAS renderers. */
  analysis?: import("./screen-projection-specialized-types").AnalysisProjection;
  /** Approved, display-only legal-document retention rows; raw schedule digests stay server-side. */
  retentionSchedules?: readonly import("./retention-schedule").ApprovedRetentionScheduleRow[];
};

export type ScreenRuntimeProjection = {
  screenId: string;
  contractVersion: "AUTHORITY_V1";
  sections: Readonly<Record<string, ScreenRuntimeProjectionSection>>;
};

export type ScreenViewModel = {
  id: string;
  /** Optional explicit journey declaration; route contracts should provide it when a screen spans domains. */
  journey?: JourneyId;
  title: string;
  route: string;
  archetype: string;
  sections: readonly ({
    id: string;
    title: string;
    purpose: string;
    component: string;
    test_id: string;
  } & Record<string, unknown>)[];
  actions: readonly ({ id: string; label: string } & Record<string, unknown>)[];
  states: readonly unknown[] | Record<string, unknown>;
  dataOperations: readonly ({
    operation_id: string;
    method: string;
    path: string;
    blocking: boolean;
  } & Record<string, unknown>)[];
  /** Contract-derived UI metadata. Route modules may omit this; ScreenPage fills it. */
  contract?: TypedScreenViewModel;
};

/**
 * The closed UI vocabulary used by the three product surfaces.  A route may
 * still carry the authority operation catalog, but presentation code consumes
 * this semantic view-model rather than operation ids or arbitrary JSON keys.
 */
export type JourneyId =
  | "J-01"
  | "J-02"
  | "J-03"
  | "J-04"
  | "J-05"
  | "J-06"
  | "J-07"
  | "J-08"
  | "J-09"
  | "J-10"
  | "J-11"
  | "J-12";

export type SemanticRegion =
  | "identity"
  | "state"
  | "priority"
  | "unknowns"
  | "evidence"
  | "next-action"
  | "response"
  | "review"
  | "triage"
  | "approval"
  | "analysis"
  | "commercial";

export type TypedSectionViewModel = {
  id: string;
  title: string;
  purpose: string;
  region: SemanticRegion;
  component: string;
  /** Effective authority component; route modules must match it exactly. */
  authorityComponent?: string | null;
  testId: string;
  order: number;
  /** Safe, human-facing data paths. Never operation ids or JSON keys. */
  fields: readonly string[];
};

export type TypedScreenViewModel = {
  screenId: string;
  journey: JourneyId;
  objectLabel: string;
  persona: string;
  answerFirst: string;
  sections: readonly TypedSectionViewModel[];
  states: readonly ScreenRuntime["state"][];
  primaryActionId: string | null;
  primaryActionLabel: string | null;
  /** Four-way decision controls are rendered only when true. */
  requiresDecisionReason: boolean;
  /** An immutable delivery/submission receipt is expected on this surface. */
  showsReceipt: boolean;
};
