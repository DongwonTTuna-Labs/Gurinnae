fn render_privacy_notification(
    state: &State,
    notification: &ValidatedPrivacyNotification,
) -> Result<(String, String, String), WorkerError> {
    let request_label = privacy_request_type_label(notification.request_type);
    match notification.notice_type {
        PrivacyNoticeType::IdentityVerificationRequired => {
            render_identity_verification_required_notification(notification, request_label)
        }
        PrivacyNoticeType::IdentityVerified => {
            render_identity_verified_notification(state, notification, request_label)
        }
        PrivacyNoticeType::Extension => {
            render_extension_notification(state, notification, request_label)
        }
        PrivacyNoticeType::Refusal => {
            render_refusal_notification(state, notification, request_label)
        }
    }
}

fn render_identity_verification_required_notification(
    notification: &ValidatedPrivacyNotification,
    request_label: &str,
) -> Result<(String, String, String), WorkerError> {
    if !matches!(
        &notification.template,
        PrivacyNoticeTemplate::IdentityVerificationRequired
    ) {
        return Err(WorkerError::Contract);
    }
    Ok(render_identity_verification_required(request_label))
}

fn render_identity_verified_notification(
    state: &State,
    notification: &ValidatedPrivacyNotification,
    request_label: &str,
) -> Result<(String, String, String), WorkerError> {
    let PrivacyNoticeTemplate::IdentityVerified { due_at, reason } = &notification.template else {
        return Err(WorkerError::Contract);
    };
    let mut reason = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "reason",
        reason.as_ref(),
        10_000,
    )?;
    let due_at = format_korean_timestamp(due_at)?;
    let subject = format!("구린네 개인정보 {request_label} 요청 신원 확인");
    let text = format!(
        "개인정보 {request_label} 요청의 신원 확인이 완료되었습니다.\n처리 기한: {due_at}\n확인 사유: {reason}"
    );
    let html = format!(
        "<p>개인정보 {request_label} 요청의 신원 확인이 완료되었습니다.</p><p>처리 기한: {due_at}</p><p>확인 사유: {}</p>",
        escape_html(&reason),
    );
    reason.zeroize();
    Ok((subject, text, html))
}

fn render_extension_notification(
    state: &State,
    notification: &ValidatedPrivacyNotification,
    request_label: &str,
) -> Result<(String, String, String), WorkerError> {
    let PrivacyNoticeTemplate::Extension {
        prior_due_at,
        due_at,
        extension_business_days,
        reason_code,
        reason,
        extension_reason,
    } = &notification.template
    else {
        return Err(WorkerError::Contract);
    };
    let mut common_reason = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "reason",
        reason.as_ref(),
        10_000,
    )?;
    let mut extension_reason = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "extensionReason",
        extension_reason.as_ref(),
        4_000,
    )?;
    let prior_due_at = format_korean_timestamp(prior_due_at)?;
    let due_at = format_korean_timestamp(due_at)?;
    let subject = format!("구린네 개인정보 {request_label} 요청 기한 연장");
    let text = format!(
        "개인정보 {request_label} 요청의 처리 기한이 연장되었습니다.\n기존 기한: {prior_due_at}\n변경 기한: {due_at}\n연장 기간: {extension_business_days}영업일\n사유 분류: {reason_code}\n연장 사유: {extension_reason}\n처리 기록: {common_reason}"
    );
    let html = format!(
        "<p>개인정보 {request_label} 요청의 처리 기한이 연장되었습니다.</p><p>기존 기한: {prior_due_at}<br>변경 기한: {due_at}<br>연장 기간: {extension_business_days}영업일</p><p>사유 분류: {}<br>연장 사유: {}<br>처리 기록: {}</p>",
        escape_html(reason_code),
        escape_html(&extension_reason),
        escape_html(&common_reason),
    );
    common_reason.zeroize();
    extension_reason.zeroize();
    Ok((subject, text, html))
}

fn render_refusal_notification(
    state: &State,
    notification: &ValidatedPrivacyNotification,
    request_label: &str,
) -> Result<(String, String, String), WorkerError> {
    let PrivacyNoticeTemplate::Refusal {
        decision_at,
        notice_due_at,
        reason_code,
        reason,
        rejection_reason,
        appeal_instructions,
    } = &notification.template
    else {
        return Err(WorkerError::Contract);
    };
    let mut common_reason = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "reason",
        reason.as_ref(),
        10_000,
    )?;
    let mut rejection_reason = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "rejectionReason",
        rejection_reason.as_ref(),
        4_000,
    )?;
    let mut appeal_instructions = decrypt_transition_text(
        state,
        notification.transition_receipt_id,
        "appealInstructions",
        appeal_instructions.as_ref(),
        4_000,
    )?;
    let decision_at = format_korean_timestamp(decision_at)?;
    let notice_due_at = format_korean_timestamp(notice_due_at)?;
    let subject = format!("구린네 개인정보 {request_label} 요청 처리 결과");
    let text = format!(
        "개인정보 {request_label} 요청이 거절되었습니다.\n결정 시각: {decision_at}\n통지 기한: {notice_due_at}\n사유 분류: {reason_code}\n거절 사유: {rejection_reason}\n이의 방법: {appeal_instructions}\n처리 기록: {common_reason}"
    );
    let html = format!(
        "<p>개인정보 {request_label} 요청이 거절되었습니다.</p><p>결정 시각: {decision_at}<br>통지 기한: {notice_due_at}</p><p>사유 분류: {}<br>거절 사유: {}<br>이의 방법: {}<br>처리 기록: {}</p>",
        escape_html(reason_code),
        escape_html(&rejection_reason),
        escape_html(&appeal_instructions),
        escape_html(&common_reason),
    );
    common_reason.zeroize();
    rejection_reason.zeroize();
    appeal_instructions.zeroize();
    Ok((subject, text, html))
}

fn render_identity_verification_required(request_label: &str) -> (String, String, String) {
    let subject = format!("구린네 개인정보 {request_label} 요청 접수");
    let text = format!("개인정보 {request_label} 요청 접수\n신원 확인 완료 전 처리 기한 미기산");
    let html = format!(
        "<p>개인정보 {request_label} 요청 접수</p><p>신원 확인 완료 전 처리 기한 미기산</p>"
    );
    (subject, text, html)
}
