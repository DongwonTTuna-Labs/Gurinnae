export { default as ScreenPage } from "./components/ScreenPage.svelte";
export * from "./local-actions";
export * from "./tokens";

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
    | "unauthenticated";
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
};
