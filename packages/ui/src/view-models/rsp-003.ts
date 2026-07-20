/**
 * Browser-safe projection for the response drafting screen.
 *
 * The submission API response is intentionally not passed to a component.  We
 * copy only the fields named by the response journey contract and turn missing
 * values into an explicit UNKNOWN state.  In particular, receipt tokens and
 * session assertions never cross this boundary.
 */

export type Rsp003Answer = {
  questionId: string | null;
  questionLabel: string | null;
  text: string | null;
  attachmentIds: readonly string[];
  updatedAt: string | null;
};

export type Rsp003Attachment = {
  id: string | null;
  filename: string | null;
  mediaType: string | null;
  sizeBytes: number | null;
  sha256: string | null;
  uploadStatus: string | null;
  scanStatus: string | null;
};

export type Rsp003Consent = {
  body: boolean | null;
  attachments: readonly string[];
  redactionAcknowledged: boolean | null;
  scopeExplanation: string | null;
  updatedAt: string | null;
};

export type Rsp003Progress = {
  draftVersion: number | null;
  requestId: string | null;
  savedAt: string | null;
  expiresAt: string | null;
  state: "DRAFT" | "SAVED" | "CONFLICT" | "UNKNOWN";
};

export type Rsp003ViewModel = {
  progress: Rsp003Progress;
  questions: readonly Rsp003Answer[];
  statement: {
    attachmentNames: readonly string[];
    answeredCount: number;
    totalCount: number;
  };
  consent: Rsp003Consent;
  save: {
    acceptedAt: string | null;
    aggregateVersion: number | null;
    auditEventId: string | null;
    status: string | null;
    links: readonly { href: string; label: string; rel: string | null }[];
  };
};

const record = (value: unknown): Record<string, unknown> | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;

const text = (value: unknown): string | null =>
  typeof value === "string" && value.trim().length > 0 ? value : null;

const integer = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= 0
    ? value
    : null;

const strings = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

function parseAnswers(value: unknown): Rsp003Answer[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    return [
      {
        questionId: text(row.questionId),
        questionLabel:
          text(row.questionLabel) ??
          text(row.prompt) ??
          text(row.questionText) ??
          text(row.question),
        text: text(row.text),
        attachmentIds: strings(row.attachmentIds),
        updatedAt: text(row.updatedAt),
      } satisfies Rsp003Answer,
    ];
  });
}

function parseAttachments(value: unknown): Rsp003Attachment[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const row = record(item);
    if (!row) return [];
    return [
      {
        id: text(row.id),
        filename: text(row.filename),
        mediaType: text(row.mediaType),
        sizeBytes: integer(row.sizeBytes),
        sha256: text(row.sha256),
        uploadStatus: text(row.uploadStatus),
        scanStatus: text(row.scanStatus),
      } satisfies Rsp003Attachment,
    ];
  });
}

function parseLinks(value: unknown): Rsp003ViewModel["save"]["links"] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const row = record(item);
    const href = text(row?.href);
    const label = text(row?.label);
    return href && label ? [{ href, label, rel: text(row?.rel) }] : [];
  });
}

/** Maps the display-safe ResponseDraftResponse and save receipt envelopes. */
export function toRsp003ViewModel(
  data: Record<string, unknown>,
): Rsp003ViewModel {
  const draft = record(data.getResponseDraft) ?? {};
  const consent = record(draft.publicationConsent) ?? {};
  const answers = parseAnswers(draft.answers);
  const attachments = parseAttachments(draft.attachments);
  const receipt = record(data.saveResponseDraft) ?? {};
  const savedAt = text(draft.savedAt);
  const acceptedAt = text(receipt.acceptedAt);
  const receiptStatus = text(receipt.status);
  const draftVersion = integer(draft.version);
  const aggregateVersion = integer(receipt.aggregateVersion);
  const state =
    receiptStatus !== null
      ? "SAVED"
      : draftVersion !== null
        ? "DRAFT"
        : "UNKNOWN";
  return {
    progress: {
      draftVersion,
      requestId: text(draft.requestId),
      savedAt,
      expiresAt: text(draft.expiresAt),
      state,
    },
    questions: answers,
    statement: {
      attachmentNames: attachments.flatMap((item) =>
        item.filename === null ? [] : [item.filename],
      ),
      answeredCount: answers.filter((item) => item.text !== null).length,
      totalCount: answers.length,
    },
    consent: {
      body:
        typeof consent.bodyConsent === "boolean"
          ? consent.bodyConsent
          : typeof consent.body === "boolean"
            ? consent.body
            : null,
      attachments: strings(consent.attachments).concat(
        Array.isArray(consent.attachmentConsents)
          ? consent.attachmentConsents.flatMap((item) => {
              const row = record(item);
              return text(row?.attachmentId) ?? text(row?.id) ?? [];
            })
          : [],
      ),
      redactionAcknowledged:
        typeof consent.redactionAcknowledged === "boolean"
          ? consent.redactionAcknowledged
          : null,
      scopeExplanation: text(consent.scopeExplanation),
      updatedAt: text(consent.updatedAt),
    },
    save: {
      acceptedAt,
      aggregateVersion,
      auditEventId: text(receipt.auditEventId),
      status: receiptStatus,
      links: parseLinks(receipt.links),
    },
  };
}
