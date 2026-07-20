import type { ProjectionField } from "./screen-projection";
import type { SpecializedProjection } from "./screen-projection-specialized-types";
import { toRsp003ViewModel } from "./view-models/rsp-003";
import { toRsp005ViewModel } from "./view-models/rsp-005";
import { toRsp006ViewModel } from "./view-models/rsp-006";

/**
 * Closed projections for public funding content and response journeys.
 * Keeping these mappers together preserves their source paths and blocked
 * semantics while allowing the facade to remain a small dispatch boundary.
 */
export function responseSpecializedFields(
  screenId: string,
  sectionId: string,
  data: Record<string, unknown>,
): SpecializedProjection | null {
  if (screenId === "PUB-023") {
    // FundingContentResponse owns its public sections under data.sections;
    // never assume a flattened top-level DTO. This closed mapper keeps the
    // browser projection truthful when the generated transport envelope is
    // absent (and therefore renders UNKNOWN rather than empty success).
    const response = data.getFundingContent;
    const record =
      response && typeof response === "object"
        ? (response as Record<string, unknown>)
        : undefined;
    const payload =
      record?.data && typeof record.data === "object"
        ? (record.data as Record<string, unknown>)
        : undefined;
    const sections = Array.isArray(payload?.sections) ? payload.sections : [];
    const section = sections.find(
      (item) =>
        item &&
        typeof item === "object" &&
        (item as Record<string, unknown>).id === sectionId,
    ) as Record<string, unknown> | undefined;
    const body = typeof section?.body === "string" ? section.body : null;
    const heading =
      typeof section?.heading === "string" ? section.heading : null;
    const status = typeof record?.status === "string" ? record.status : null;
    if (sectionId === "reports") {
      const reports = data.listTransparencyReports;
      const reportValue =
        reports && typeof reports === "object"
          ? (reports as Record<string, unknown>)
          : undefined;
      const items = Array.isArray(reportValue?.items) ? reportValue.items : [];
      return {
        fields: [
          {
            name: "reports",
            label: "보고서",
            value: body ?? (items.length ? `${items.length}건` : null),
            known: body !== null || items.length > 0,
            source: "getFundingContent.data.sections[reports]",
          },
          {
            name: "status",
            label: "현재 상태",
            value: status,
            known: status !== null,
            source: "getFundingContent.status",
          },
        ],
        blocked: false,
      };
    }
    return {
      fields: [
        {
          name: sectionId,
          label: heading ?? sectionId,
          value: body,
          known: body !== null,
          source: `getFundingContent.data.sections[${sectionId}]`,
        },
        {
          name: "status",
          label: "현재 상태",
          value: status,
          known: status !== null,
          source: "getFundingContent.status",
        },
      ],
      blocked: false,
    };
  }
  if (screenId === "RSP-003") {
    const vm = toRsp003ViewModel(data);
    if (sectionId === "progress") {
      return {
        fields: [
          {
            name: "requestId",
            label: "요청 식별자",
            value: vm.progress.requestId,
            known: vm.progress.requestId !== null,
            source: "getResponseDraft.requestId",
          },
          {
            name: "version",
            label: "초안 버전",
            value: vm.progress.draftVersion,
            known: vm.progress.draftVersion !== null,
            source: "getResponseDraft.version",
          },
          {
            name: "draft_version",
            label: "초안 버전",
            value: vm.progress.draftVersion,
            known: vm.progress.draftVersion !== null,
            source: "getResponseDraft.version",
          },
          {
            name: "request_id",
            label: "요청 식별자",
            value: vm.progress.requestId,
            known: vm.progress.requestId !== null,
            source: "getResponseDraft.requestId",
          },
          {
            name: "draft_state",
            label: "초안 상태",
            value: vm.progress.state,
            known: true,
            source: "getResponseDraft + saveResponseDraft",
          },
        ],
        blocked: vm.progress.requestId === null,
      };
    }
    if (sectionId === "questions") {
      const fields: ProjectionField[] = vm.questions.flatMap(
        (answer, index) =>
          [
            {
              name: `question_${index + 1}`,
              label: answer.questionLabel ?? `질문 ${index + 1}`,
              value: answer.questionId,
              known: answer.questionId !== null,
              source: "getResponseDraft.answers[].questionId",
            },
            {
              name: `answer_${index + 1}`,
              label: `${answer.questionLabel ?? `질문 ${index + 1}`} 답변`,
              value: answer.text,
              known: answer.text !== null,
              source: "getResponseDraft.answers[].text",
            },
          ] satisfies ProjectionField[],
      );
      fields.push({
        name: "answers",
        label: "답변",
        value: vm.questions.length,
        known: vm.questions.length > 0,
        source: "getResponseDraft.answers",
      });
      return { fields, blocked: vm.questions.length === 0 };
    }
    if (sectionId === "statement") {
      return {
        fields: [
          {
            name: "answered_count",
            label: "답변한 항목",
            value: vm.statement.answeredCount,
            known: vm.statement.totalCount > 0,
            source: "getResponseDraft.answers",
          },
          {
            name: "total_count",
            label: "전체 질문",
            value: vm.statement.totalCount,
            known: vm.statement.totalCount > 0,
            source: "getResponseDraft.answers",
          },
          {
            name: "attachments",
            label: "첨부 파일",
            value: vm.statement.attachmentNames.join(" · ") || "없음",
            known: vm.statement.totalCount > 0,
            source: "getResponseDraft.attachments",
          },
        ],
        blocked: vm.statement.totalCount === 0,
      };
    }
    if (sectionId === "consent") {
      return {
        fields: [
          {
            name: "body_consent",
            label: "본문 공개 동의",
            value: vm.consent.body,
            known: vm.consent.body !== null,
            source: "getResponseDraft.publicationConsent.body",
          },
          {
            name: "redaction_acknowledged",
            label: "비식별화 확인",
            value: vm.consent.redactionAcknowledged,
            known: vm.consent.redactionAcknowledged !== null,
            source: "getResponseDraft.publicationConsent.redactionAcknowledged",
          },
          {
            name: "scope_explanation",
            label: "공개 범위 설명",
            value: vm.consent.scopeExplanation,
            known: vm.consent.scopeExplanation !== null,
            source: "getResponseDraft.publicationConsent.scopeExplanation",
          },
        ],
        blocked: vm.consent.redactionAcknowledged !== true,
      };
    }
    return {
      fields: [
        {
          name: "saved_at",
          label: "저장 시각",
          value: vm.progress.savedAt,
          known: vm.progress.savedAt !== null,
          source: "getResponseDraft.savedAt",
        },
        {
          name: "expires_at",
          label: "만료 시각",
          value: vm.progress.expiresAt,
          known: vm.progress.expiresAt !== null,
          source: "getResponseDraft.expiresAt",
        },
        {
          name: "receipt_status",
          label: "저장 상태",
          value: vm.save.status,
          known: vm.save.status !== null,
          source: "saveResponseDraft.status",
        },
      ],
      blocked: vm.progress.state === "CONFLICT",
    };
  }
  if (screenId === "RSP-005") {
    const vm = toRsp005ViewModel(data);
    const common = (section: string): ProjectionField[] => {
      if (section === "answers")
        return vm.answers.flatMap(
          (answer, index) =>
            [
              {
                name: `question_${index + 1}`,
                label: `질문 ${index + 1}`,
                value: answer.questionId,
                known: answer.questionId !== null,
                source: "getResponseSubmissionPreview.answers[].questionId",
              },
              {
                name: `answer_${index + 1}`,
                label: `답변 ${index + 1}`,
                value: answer.text,
                known: answer.text !== null,
                source: "getResponseSubmissionPreview.answers[].text",
              },
            ] satisfies ProjectionField[],
        );
      if (section === "attachments")
        return vm.attachments.flatMap(
          (attachment, index) =>
            [
              {
                name: `attachment_${index + 1}`,
                label: `첨부 파일 ${index + 1}`,
                value: attachment.filename,
                known: attachment.filename !== null,
                source: "getResponseSubmissionPreview.attachments[].filename",
              },
              {
                name: `scan_${index + 1}`,
                label: `검사 상태 ${index + 1}`,
                value: attachment.scanStatus,
                known: attachment.scanStatus !== null,
                source: "getResponseSubmissionPreview.attachments[].scanStatus",
              },
            ] satisfies ProjectionField[],
        );
      if (section === "consent")
        return [
          {
            name: "body_consent",
            label: "본문 공개 동의",
            value: vm.consent.body,
            known: vm.consent.body !== null,
            source: "getResponseSubmissionPreview.publicationConsent.body",
          },
          {
            name: "redaction_acknowledged",
            label: "비식별화 확인",
            value: vm.consent.redactionAcknowledged,
            known: vm.consent.redactionAcknowledged !== null,
            source:
              "getResponseSubmissionPreview.publicationConsent.redactionAcknowledged",
          },
          {
            name: "attachment_consent_count",
            label: "첨부 공개 동의 수",
            value: vm.consent.attachmentCount,
            known: true,
            source:
              "getResponseSubmissionPreview.publicationConsent.attachments",
          },
        ];
      if (section === "authority")
        return [
          {
            name: "authority_status",
            label: "권위 확인 상태",
            value: vm.authority.status,
            known: true,
            source: "getResponseSubmissionPreview.authority",
          },
        ];
      return [
        {
          name: "missing_answers",
          label: "미답변 항목",
          value: vm.consequence.missingAnswerCount,
          known: true,
          source: "getResponseSubmissionPreview.answers",
        },
        {
          name: "pending_attachments",
          label: "대기 중인 첨부",
          value: vm.consequence.pendingAttachmentCount,
          known: true,
          source: "getResponseSubmissionPreview.attachments",
        },
        {
          name: "submit_blocked",
          label: "제출 차단 여부",
          value: vm.consequence.blocked,
          known: true,
          source: "submission guard",
        },
      ];
    };
    return {
      fields: common(sectionId),
      blocked:
        sectionId === "authority"
          ? vm.authority.status !== "CONFIRMED"
          : sectionId === "consequence"
            ? vm.consequence.blocked
            : false,
    };
  }
  if (screenId === "RSP-006") {
    const vm = toRsp006ViewModel(data);
    const receipt = [
      {
        name: "receipt_id",
        label: "제출 영수증 식별자",
        value: vm.receiptId,
        known: vm.receiptId !== null,
        source: "getResponseReceipt.id",
      },
      {
        name: "receipt_status",
        label: "제출 영수증 상태",
        value: vm.receiptStatus,
        known: vm.receiptStatus !== null,
        source: "getResponseReceipt.status",
      },
      {
        name: "submitted_at",
        label: "제출 시각",
        value: vm.submittedItems.submittedAt,
        known: vm.submittedItems.submittedAt !== null,
        source: "getResponseReceipt.data.submittedAt",
      },
      {
        name: "submission_digest",
        label: "제출 무결성 지문",
        value: vm.submittedItems.submissionDigest,
        known: vm.submittedItems.submissionDigest !== null,
        source: "getResponseReceipt.data.submissionDigest",
      },
    ] satisfies ProjectionField[];
    return {
      fields:
        sectionId === "receipt" || sectionId === "download"
          ? receipt
          : [
              {
                name: "request_id",
                label: "요청 식별자",
                value: vm.submittedItems.requestId,
                known: vm.submittedItems.requestId !== null,
                source: "getResponseReceipt.data.requestId",
              },
              {
                name: "answer_count",
                label: "답변 수",
                value: vm.submittedItems.answerCount,
                known: vm.submittedItems.answerCount !== null,
                source: "getResponseReceipt.data.answerCount",
              },
              {
                name: "attachment_count",
                label: "첨부 수",
                value: vm.submittedItems.attachmentCount,
                known: vm.submittedItems.attachmentCount !== null,
                source: "getResponseReceipt.data.attachmentCount",
              },
            ],
      blocked: sectionId === "receipt" && vm.receiptId === null,
    };
  }
  return null;
}
