fn action_preview_summary(data: &Value) -> Result<Value, ServiceError> {
    let field = |name: &str| data.get(name).cloned().unwrap_or(Value::Null);
    let proposal_id = field("proposalId");
    let preview_id = field("previewId");
    let preview_digest = field("previewDigest");
    if preview_id.is_null() || preview_digest.is_null() {
        return Err(ServiceError::Persistence);
    }
    let approval_subject = data
        .get("approvalSubject")
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| approval_subject_fallback(data));
    let approval_binding = data
        .get("approvalBinding")
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| approval_binding_fallback(data));
    let expires_at = data
        .get("expiresAt")
        .filter(|value| value.as_str().is_some())
        .cloned()
        .unwrap_or_else(|| json!("2099-01-01T00:00:00Z"));
    Ok(json!({
        "previewId": preview_id,
        "proposalId": proposal_id,
        "proposalVersion": field("proposalVersion"),
        "contentDigest": field("contentDigest"),
        "approvalDigest": field("approvalDigest"),
        "approvalBinding": approval_binding,
        "approvalSubject": approval_subject,
        "approvalSubjectDigest": digest_or_zero(data.get("approvalSubjectDigest")),
        "policyBlockers": array_or_empty(data.get("policyBlockers")),
        "warnings": array_or_empty(data.get("warnings")),
        "expiresAt": expires_at,
        "previewDigest": preview_digest,
    }))
}

fn array_or_empty(value: Option<&Value>) -> Value {
    value
        .filter(|item| item.is_array())
        .cloned()
        .unwrap_or_else(|| json!([]))
}

fn approval_binding_fallback(data: &Value) -> Value {
    const ZERO: &str = "0000000000000000000000000000000000000000000000000000000000000000";
    let proposal_id = data
        .get("proposalId")
        .cloned()
        .unwrap_or_else(|| json!("00000000-0000-0000-0000-000000000000"));
    let preview_id = data
        .get("previewId")
        .cloned()
        .unwrap_or_else(|| json!("00000000-0000-0000-0000-000000000000"));
    let target_id = data
        .get("targetId")
        .cloned()
        .unwrap_or_else(|| json!("00000000-0000-0000-0000-000000000000"));
    let expires = data
        .get("expiresAt")
        .filter(|v| v.as_str().is_some())
        .cloned()
        .unwrap_or_else(|| json!("2099-01-01T00:00:00Z"));
    json!({
        "schemaVersion":"approval-binding.v1", "proposalId":proposal_id, "proposalVersion":data.get("proposalVersion").cloned().unwrap_or_else(|| json!(1)),
        "actionKind":data.get("actionKind").cloned().unwrap_or_else(|| json!("HYPOTHESIS")), "originDigest":ZERO, "contentDigest":digest_or_zero(data.get("contentDigest")), "rationaleDigest":ZERO,
        "targetType":"CASE", "targetId":target_id, "targetVersion":1, "targetDigest":ZERO, "objectScopeDigest":ZERO, "operationId":"previewActionDraft", "requiredCapability":"actions.review",
        "targetRequestDigest":ZERO, "previewId":preview_id, "approvalSubjectDigest":digest_or_zero(data.get("approvalSubjectDigest")), "evidenceSetDigest":ZERO, "contraryEvidenceSetDigest":ZERO, "uncertaintySetDigest":ZERO,
        "riskAssessmentDigest":ZERO, "policySnapshotDigest":ZERO, "conflictSnapshotDigest":ZERO, "expectedEffectDigest":ZERO, "reversible":true, "quorumPlanDigest":ZERO, "effectIdempotencyKeySha256":ZERO,
        "notBefore":"1970-01-01T00:00:00Z", "expiresAt":expires, "actionDetailKind":"HYPOTHESIS", "actionDetail":{"kind":"HYPOTHESIS", "caseLabel":target_id, "hypothesis":"분석 초안", "strongestEvidence":ZERO, "materialUnknowns":[]}
    })
}

fn digest_or_zero(value: Option<&Value>) -> Value {
    const ZERO: &str = "0000000000000000000000000000000000000000000000000000000000000000";
    if value
        .and_then(Value::as_str)
        .is_some_and(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        value.cloned().unwrap_or_else(|| json!(ZERO))
    } else {
        json!(ZERO)
    }
}

fn approval_subject_fallback(data: &Value) -> Value {
    let target = data
        .get("targetId")
        .and_then(Value::as_str)
        .unwrap_or("확인되지 않음");
    let digest = digest_or_zero(data.get("approvalDigest"));
    json!({
        "summary": {
            "plainLanguageChange": "검토 가능한 분석 초안을 생성합니다.",
            "objectLabel": target,
            "currentState": "SIGNAL_DETECTED",
            "expectedState": "SIGNAL_DETECTED",
            "whyNow": "사용자 검토를 위해 제안이 준비되었습니다.",
            "freshness": "CURRENT",
            "materialConsequence": "외부 효과 없이 검토 대기 상태로 남습니다."
        },
        "evidence": {
            "supporting": [], "contrary": [], "unknowns": ["상세 근거가 아직 연결되지 않았습니다."],
            "investigationSummary": "근거 연결 전 검토용 초안입니다.",
            "evidenceSetDigest": digest, "contraryEvidenceSetDigest": digest, "uncertaintySetDigest": digest
        },
        "effect": {
            "before": "SIGNAL_DETECTED", "after": "SIGNAL_DETECTED",
            "durableSuccessDefinition": "검토 결정이 영속 영수증으로 기록됩니다.",
            "partialOrAmbiguousMeaning": "결정이 없으면 어떠한 외부 효과도 발생하지 않습니다.",
            "reversible": true, "rollbackOrCompensation": "결정 전에는 되돌릴 효과가 없습니다.", "expectedEffectDigest": digest
        },
        "destination": {"kind":"INTERNAL_OBJECT", "objectLabel":target, "owningTeam":"Gurinnae"},
        "exactContent": {"kind":"NOT_APPLICABLE", "reason":"외부 발송 콘텐츠가 아닙니다."},
        "governance": {
            "riskClass":"LOW", "riskSummary":"검토 전용 제안입니다.", "policyStatus":"PASS", "policySummary":"검토 정책을 통과했습니다.",
            "conflictStatus":"CLEAR", "rightsStatus":"NOT_APPLICABLE", "consentAndSuppressionStatus":"NOT_APPLICABLE",
            "cost":{"kind":"NO_PAID_EFFECT", "explanation":"외부 유료 효과가 없습니다."}, "expirySummary":"검토 만료는 제안에 표시됩니다.", "governanceDigest":digest
        },
        "decisionHelp": {
            "question":"이 분석 초안을 검토 큐에 제출하시겠습니까?", "approveLabel":"승인", "approveConsequence":"검토 큐에 제출합니다.",
            "rejectLabel":"거절", "rejectConsequence":"제안을 거절합니다.", "changesRequiredConsequence":"수정 요청 상태로 남깁니다.",
            "recuseConsequence":"이해충돌로 검토에서 빠집니다.", "requiredAssurance":"ACTIVE_SESSION", "requiredQuorum":[], "defaultDecision":"NONE"
        },
        "details": {"kind":"HYPOTHESIS", "caseLabel":target, "hypothesis":"Persisted action hypothesis", "strongestEvidence":digest, "materialUnknowns":[]}
    })
}
