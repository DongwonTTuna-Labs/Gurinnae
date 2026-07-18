export { default as ScreenPage } from "./components/ScreenPage.svelte";
export * from "./local-actions";
export * from "./tokens";
export * from "./screen-contract";
export * from "./decision-contract";
export * from "./view-models/int-002";
export * from "./view-models/ops-004";
export * from "./view-models/rsp-006";

export type ScreenSection = ScreenViewModel["sections"][number];
export type ScreenSectionProps = {
  section: ScreenSection;
  screen: ScreenViewModel;
  runtime: ScreenRuntime;
  index: number;
};

export type ScreenField = {
  name: string;
  label: string;
  type: "text" | "number" | "boolean" | "date" | "datetime-local" | "json";
  required: boolean;
  options?: readonly string[];
  value?: string | number | boolean;
  readonly?: boolean;
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
    | "success"
    | "empty"
    | "partial"
    | "stale"
    | "error"
    | "unauthenticated"
    | "unauthorized"
    | "forbidden"
    | "conflict"
    | "receipt"
    | "offline"
    | "saving"
    | "saved"
    | "validation-error"
    | "session-expiring"
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
  errors: readonly string[];
  forms: Record<string, readonly ScreenField[]>;
  formOperationIds?: Readonly<Record<string, string>>;
  idempotencyKeys?: Readonly<Record<string, string>>;
  botChallenge?: BotChallengeRuntime;
  attachmentUpload?: AttachmentUploadRuntime;
  attachmentRemoval?: AttachmentRemovalRuntime;
  csrfToken?: string;
  notice?: string;
  pathname?: string;
  allowedActionIds?: readonly string[];
  actorDisplayName?: string;
  sessionExpiresAt?: string;
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
