async fn prepare(state: &State, event: &ClaimedEvent) -> Result<(Uuid, EmailMessage), WorkerError> {
    let (to, subject, text, html) = match event.event_type.as_str() {
        "attachment.scan_completed.v1" => prepare_scan_completed(state, event).await?,
        "intake.contact_received.v1" => prepare_contact_received(state, event).await?,
        "notification.subscription_verification_requested.v1" => {
            prepare_subscription_verification(state, event).await?
        }
        "notification.correction_received.v1" => prepare_correction_received(state, event).await?,
        "notification.correction_resolved.v1" => prepare_correction_resolved(state, event).await?,
        "notification.response_extension_requested.v1" => {
            prepare_response_extension(state, event).await?
        }
        "notification.response_request_delivery_requested.v1" => {
            prepare_response_request(state, event).await?
        }
        "notification.response_submitted.v2" => prepare_response_submitted_v2(state, event).await?,
        "notification.user_invitation_requested.v1" => {
            prepare_user_invitation(state, event).await?
        }
        _ => return Err(WorkerError::Database),
    };
    let recipient_hash = sha256_hex(to.as_bytes());
    let delivery_id:Uuid=sqlx::query_scalar!(
        "INSERT INTO ops.email_deliveries(message_type,recipient_hash,template_version,object_type,object_id,status,attempt_count) VALUES($1,$2,'v1',$3,$4,'SENDING',1) ON CONFLICT(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL DO UPDATE SET status='SENDING',attempt_count=ops.email_deliveries.attempt_count+1,last_error_code=NULL RETURNING id",
        &event.event_type,
        recipient_hash,
        "notification",
        event.aggregate_id,
    )
     .fetch_one(&state.pool).await.map_err(|_|WorkerError::Database)?;
    Ok((
        delivery_id,
        EmailMessage {
            from: state.from_email.clone(),
            to,
            subject,
            text_body: text,
            html_body: html,
        },
    ))
}

async fn prepare_scan_completed(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let attachment_id =
            pointer_uuid(&event.payload, "/attachment_id").map_err(|_| WorkerError::Contract)?;
        if attachment_id != event.aggregate_id {
            return Err(WorkerError::Contract);
        }
        let status = event
            .payload
            .get("scan_status")
            .and_then(serde_json::Value::as_str)
            .filter(|value| matches!(*value, "CLEAN" | "INFECTED" | "FAILED"))
            .ok_or(WorkerError::Contract)?;
        let digest = event
            .payload
            .get("sha256")
            .and_then(serde_json::Value::as_str)
            .filter(|value| {
                value.len() == 64
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            })
            .ok_or(WorkerError::Contract)?;
        (
            state.reply_to.clone(),
            format!("구린네 첨부 검사 결과: {status}"),
            format!(
                "첨부 {} 검사 상태: {status}, SHA-256: {}",
                event.aggregate_id, digest
            ),
            format!(
                "<p>첨부 {} 검사 상태: <strong>{status}</strong></p><p>SHA-256: {}</p>",
                event.aggregate_id, digest
            ),
        )
    })
}

async fn prepare_contact_received(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let subject: String = sqlx::query_scalar!(
            "SELECT subject FROM intake.contact_requests WHERE id=$1",
            event.aggregate_id,
        )
        .fetch_optional(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?
        .ok_or(WorkerError::Database)?;
        let html_subject = escape_html(&subject);
        (
            state.reply_to.clone(),
            "구린네 새 문의 접수".to_owned(),
            format!(
                "새 문의가 접수되었습니다. ID: {}\n제목: {subject}",
                event.aggregate_id
            ),
            format!(
                "<p>새 문의가 접수되었습니다.</p><p>ID: {}</p><p>제목: {html_subject}</p>",
                event.aggregate_id,
            ),
        )
    })
}

async fn prepare_subscription_verification(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let verification = derived_token(
            &state.token_hmac_key,
            "subscription-verification",
            event.aggregate_id,
        )?;
        let management = derived_token(
            &state.token_hmac_key,
            "subscription-management",
            event.aggregate_id,
        )?;
        let row = sqlx::query!(
                "SELECT email_encrypted,locale FROM intake.subscriptions WHERE id=$1 AND status='PENDING'",
                event.aggregate_id,
            )
            .fetch_one(&state.pool).await.map_err(|_|WorkerError::Database)?;
        let encrypted = row.email_encrypted;
        let to = decrypt_email(
            state,
            "intake.subscriptions",
            "email_encrypted",
            event.aggregate_id,
            &encrypted,
        )?;
        let verify_url = format!("{}/subscribe?token={}", state.public_base_url, verification);
        let manage_url = format!(
            "{}/subscription/manage/exchange?token={}",
            state.public_base_url, management
        );
        (
            to,
            "구린네 구독 확인".to_owned(),
            format!("구독 확인: {verify_url}\n향후 구독 관리: {manage_url}"),
            format!(
                "<p><a href=\"{verify_url}\">구독 확인</a></p><p><a href=\"{manage_url}\">구독 관리</a></p>"
            ),
        )
    })
}

async fn prepare_correction_received(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let token = derived_token(
            &state.token_hmac_key,
            "correction-receipt",
            event.aggregate_id,
        )?;
        let encrypted: Vec<u8> = sqlx::query_scalar!(
            "SELECT contact_email_encrypted FROM intake.correction_requests WHERE id=$1",
            event.aggregate_id,
        )
        .fetch_one(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
        let to = decrypt_email(
            state,
            "intake.correction_requests",
            "contact_email_encrypted",
            event.aggregate_id,
            &encrypted,
        )?;
        let url = format!(
            "{}/correction-request/receipt/exchange?token={}",
            state.public_base_url, token
        );
        (
            to,
            "구린네 정정 요청 접수".to_owned(),
            format!("정정 요청이 접수되었습니다. 영수증: {url}"),
            format!("<p>정정 요청이 접수되었습니다. <a href=\"{url}\">영수증 보기</a></p>"),
        )
    })
}

async fn prepare_response_extension(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let row = sqlx::query!(
            "SELECT r.id,r.recipient_email_encrypted,x.requested_due_at \
                 FROM intake.response_extension_requests x JOIN editorial.response_requests r \
                   ON r.id=x.response_request_id WHERE x.id=$1",
            event.aggregate_id,
        )
        .fetch_optional(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?
        .ok_or(WorkerError::Database)?;
        let request_id = row.id;
        let encrypted = row.recipient_email_encrypted;
        let to = decrypt_email(
            state,
            "editorial.response_requests",
            "recipient_email_encrypted",
            request_id,
            &encrypted,
        )?;
        let due = row.requested_due_at;
        (
            to,
            "구린네 소명 기한 연장 요청 접수".to_owned(),
            format!("소명 기한 연장 요청이 접수되었습니다. 요청 기한: {due}"),
            format!("<p>소명 기한 연장 요청이 접수되었습니다.</p><p>요청 기한: {due}</p>"),
        )
    })
}

async fn prepare_response_request(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let row = sqlx::query!(
                "SELECT recipient_email_encrypted,party_name,due_at FROM editorial.response_requests WHERE id=$1",
                event.aggregate_id,
            )
            .fetch_optional(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?
            .ok_or(WorkerError::Database)?;
        let encrypted = row.recipient_email_encrypted;
        let to = decrypt_email(
            state,
            "editorial.response_requests",
            "recipient_email_encrypted",
            event.aggregate_id,
            &encrypted,
        )?;
        let access_token = random_token()?;
        let access_token_hash = token_hmac(&state.token_hmac_key, &access_token)?;
        let otp = response_otp(&state.token_hmac_key, &access_token_hash)?;
        sqlx::query!(
            "INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at) \
                 VALUES($1,$2,clock_timestamp()+interval '14 days')",
            event.aggregate_id,
            access_token_hash,
        )
        .execute(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
        let url = format!(
            "{}/respond/access?token={access_token}",
            state.response_base_url
        );
        let party = row.party_name;
        (
            to,
            "구린네 소명 요청".to_owned(),
            format!("{party} 담당자께 소명을 요청드립니다. 제출: {url}\n이메일 확인 코드: {otp}"),
            format!(
                "<p>{party} 담당자께 소명을 요청드립니다.</p><p><a href=\"{url}\">소명 제출</a></p><p>이메일 확인 코드: <strong>{otp}</strong></p>"
            ),
        )
    })
}

async fn prepare_user_invitation(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok({
        let row = sqlx::query!(
            "SELECT email::text email,display_name FROM ops.users WHERE id=$1 AND status='INVITED'",
            event.aggregate_id,
        )
        .fetch_optional(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?
        .ok_or(WorkerError::Database)?;
        let to = row.email.ok_or(WorkerError::Database)?;
        let display = row.display_name;
        (
            to,
            "구린네 내부 사용자 초대".to_owned(),
            format!("{display}님이 구린네 내부 검토 시스템에 초대되었습니다."),
            format!("<p>{display}님이 구린네 내부 검토 시스템에 초대되었습니다.</p>"),
        )
    })
}

async fn prepare_correction_resolved(
    state: &State,
    event: &ClaimedEvent,
) -> Result<(String, String, String, String), WorkerError> {
    Ok((
        state.reply_to.clone(),
        "구린네 정정 검토 완료".to_owned(),
        format!(
            "정정 검토가 완료되었습니다. 정정 ID: {}",
            event.aggregate_id
        ),
        format!(
            "<p>정정 검토가 완료되었습니다.</p><p>정정 ID: {}</p>",
            event.aggregate_id
        ),
    ))
}

include!("response_submission_notification.rs");
