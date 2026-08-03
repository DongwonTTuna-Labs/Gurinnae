import {
  type PublicDetailStatusContext,
  type PublicStatusNoticeKind,
  publicDetailStatusContext,
  publicLedgerCell,
  publicStatusNotice,
} from "@gurine/ui";
import * as v from "valibot";
import { sourceResponse } from "./public-presentation-schemas";

type ContextFieldBinding = Readonly<{
  path: readonly string[];
  fieldName: string;
  label: string;
}>;

type PublicStatusBinding = Readonly<{
  operationId: string;
  subject: ContextFieldBinding;
  status?: ContextFieldBinding;
  notice: Readonly<{
    path: readonly string[];
    kind: PublicStatusNoticeKind;
  }>;
}>;

const PUBLIC_STATUS_BINDINGS: Readonly<Record<string, PublicStatusBinding>> = {
  "PUB-004": {
    operationId: "getPublicCase",
    subject: { path: ["title"], fieldName: "title", label: "사건명" },
    status: {
      path: ["publicState"],
      fieldName: "publicState",
      label: "공개 상태",
    },
    notice: { path: ["nonConclusion"], kind: "NON_CONCLUSION" },
  },
  "PUB-005": {
    operationId: "getPublicCaseRevision",
    subject: {
      path: ["content", "case", "title"],
      fieldName: "title",
      label: "사건명",
    },
    status: {
      path: ["content", "case", "publicState"],
      fieldName: "publicState",
      label: "공개 상태",
    },
    notice: {
      path: ["content", "nonConclusion"],
      kind: "NON_CONCLUSION",
    },
  },
  "PUB-006": {
    operationId: "getCaseReproducibility",
    subject: {
      path: ["caseSlug"],
      fieldName: "caseSlug",
      label: "사건 식별자",
    },
    notice: { path: ["nonConclusion"], kind: "NON_CONCLUSION" },
  },
  "PUB-008": {
    operationId: "getAgency",
    subject: { path: ["name"], fieldName: "name", label: "기관명" },
    status: {
      path: ["freshness", "status"],
      fieldName: "status",
      label: "수집 상태",
    },
    notice: { path: ["interpretationNotice"], kind: "INTERPRETATION" },
  },
  "PUB-010": {
    operationId: "getSupplier",
    subject: { path: ["name"], fieldName: "name", label: "업체명" },
    status: {
      path: ["freshness", "status"],
      fieldName: "status",
      label: "수집 상태",
    },
    notice: { path: ["interpretationNotice"], kind: "INTERPRETATION" },
  },
  "PUB-012": {
    operationId: "getContract",
    subject: { path: ["title"], fieldName: "title", label: "계약명" },
    status: { path: ["status"], fieldName: "status", label: "계약 상태" },
    notice: { path: ["interpretationNotice"], kind: "INTERPRETATION" },
  },
  "PUB-017": {
    operationId: "getSource",
    subject: {
      path: ["data", "displayName"],
      fieldName: "displayName",
      label: "출처명",
    },
    status: {
      path: ["data", "status"],
      fieldName: "status",
      label: "수집 상태",
    },
    notice: {
      path: ["data", "interpretationNotice"],
      kind: "INTERPRETATION",
    },
  },
  "PUB-019": {
    operationId: "getCorrection",
    subject: {
      path: ["data", "summary"],
      fieldName: "summary",
      label: "정정 요약",
    },
    status: {
      path: ["data", "publicState"],
      fieldName: "publicState",
      label: "공개 상태",
    },
    notice: {
      path: ["data", "nonConclusion"],
      kind: "NON_CONCLUSION",
    },
  },
};

export function publicStatusPresentation(
  screenId: string,
  data: Readonly<Record<string, unknown>>,
): PublicDetailStatusContext | undefined {
  const binding = PUBLIC_STATUS_BINDINGS[screenId];
  if (!binding) return undefined;
  const response = data[binding.operationId];
  if (response === undefined)
    throw new Error(`공개 상태 고지 주 응답 누락: ${binding.operationId}`);
  const validatedResponse =
    screenId === "PUB-017" ? v.parse(sourceResponse, response) : response;
  const envelope = record(validatedResponse, `${binding.operationId} 응답`);
  const subject = contextField(envelope, binding.operationId, binding.subject);
  const status = binding.status
    ? contextField(envelope, binding.operationId, binding.status)
    : undefined;
  const noticeValue = requiredText(
    envelope,
    binding.notice.path,
    binding.operationId,
  );
  return publicDetailStatusContext(
    subject,
    status,
    publicStatusNotice(binding.notice.kind, noticeValue),
  );
}

function contextField(
  envelope: Readonly<Record<string, unknown>>,
  operationId: string,
  binding: ContextFieldBinding,
) {
  const value = requiredText(envelope, binding.path, operationId);
  const cell = publicLedgerCell(binding.fieldName, binding.label, value);
  return { label: binding.label, text: cell.text };
}

function requiredText(
  envelope: Readonly<Record<string, unknown>>,
  path: readonly string[],
  operationId: string,
): string {
  let value: unknown = envelope;
  for (const segment of path) {
    value = record(value, `${operationId}.${path.join(".")}`)[segment];
  }
  if (typeof value !== "string" || !value.trim())
    throw new Error(
      `공개 상태 고지 응답 계약 불일치: ${operationId}.${path.join(".")}`,
    );
  return value;
}

function record(value: unknown, source: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error(`공개 상태 고지 응답 계약 불일치: ${source}`);
  return value as Record<string, unknown>;
}
