async fn process_publication_created(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let review_snapshot_id = publication_review_snapshot_id(&event.payload)?;
    let case = sqlx::query!(
        "SELECT c.public_slug,c.title,btrim(a.sigungu_code::text) AS \"sigungu_code?\" \
         FROM editorial.cases c \
         LEFT JOIN editorial.publication_revisions r \
           ON r.case_id=c.id AND r.review_snapshot_id=$2 \
         LEFT JOIN core.agencies a ON a.id::text=r.public_payload->>'agencyId' \
         WHERE c.id=$1",
        event.aggregate_id,
        review_snapshot_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Database)?;
    let slug = case.public_slug;
    let title = case.title;
    let subscriptions = sqlx::query!(
        "SELECT id,email_encrypted,locale,topics FROM intake.subscriptions \
         WHERE status='ACTIVE' AND frequency='IMMEDIATE' ORDER BY id",
    )
    .fetch_all(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let url = format!(
        "{}/cases/{}",
        state.public_base_url,
        slug.unwrap_or_else(|| event.aggregate_id.to_string())
    );
    let mut delivered = 0_u64;
    for subscription in subscriptions {
        if !subscription_matches_publication(&subscription.topics, case.sigungu_code.as_deref()) {
            continue;
        }
        match deliver_publication_subscriber(
            state,
            job,
            event,
            &title,
            &url,
            subscription.id,
            &subscription.email_encrypted,
        )
        .await?
        {
            Some(count) => delivered += count,
            None => return Ok(()),
        }
    }
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
        &event.consumer_id,
        event.id,
    )
    .execute(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if changed != 1 {
        return Err(WorkerError::Database);
    }
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({"deliveredSubscribers":delivered}),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(event_id=%event.id,case_id=%event.aggregate_id,delivered,"publication notification fanout completed");
    Ok(())
}

fn publication_review_snapshot_id(payload: &serde_json::Value) -> Result<Uuid, WorkerError> {
    pointer_uuid(payload, "/reviewSnapshotId").map_err(|_| WorkerError::Contract)
}

fn subscription_matches_publication(
    topics: &serde_json::Value,
    publication_sigungu_code: Option<&str>,
) -> bool {
    let Some(scopes) = topics.as_array() else {
        return false;
    };
    scopes.iter().any(|scope| {
        let Some(scope_type) = scope.get("scopeType").and_then(serde_json::Value::as_str) else {
            return false;
        };
        match scope_type {
            "GLOBAL" | "QUERY" | "CASE" | "AGENCY" | "SUPPLIER" | "CORRECTIONS" => true,
            "REGION" => scope
                .get("scopeRef")
                .and_then(serde_json::Value::as_str)
                .zip(publication_sigungu_code)
                .is_some_and(|(scope_ref, sigungu_code)| scope_ref == sigungu_code),
            _ => false,
        }
    })
}

async fn deliver_publication_subscriber(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
    title: &str,
    url: &str,
    subscription_id: Uuid,
    encrypted: &[u8],
) -> Result<Option<u64>, WorkerError> {
    let to = decrypt_email(
        state,
        "intake.subscriptions",
        "email_encrypted",
        subscription_id,
        encrypted,
    )?;
    let recipient_hash = sha256_hex(to.as_bytes());
    let row = sqlx::query!(
        "INSERT INTO ops.email_deliveries(message_type,recipient_hash,template_version, \
         object_type,object_id,status,attempt_count) \
         VALUES($1,$2,'v1','publication',$3,'SENDING',1) \
         ON CONFLICT(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL \
         DO UPDATE SET status=CASE WHEN ops.email_deliveries.status='DELIVERED' \
           THEN 'DELIVERED' ELSE 'SENDING' END, \
           attempt_count=CASE WHEN ops.email_deliveries.status='DELIVERED' \
             THEN ops.email_deliveries.attempt_count ELSE ops.email_deliveries.attempt_count+1 END, \
           last_error_code=NULL RETURNING id,status",
        &event.event_type,
        recipient_hash,
        event.aggregate_id,
    )
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let delivery_id = row.id;
    let status = row.status;
    if status == "DELIVERED" {
        return Ok(Some(1));
    }
    let message = EmailMessage {
        from: state.from_email.clone(),
        to,
        subject: format!("구린네 새 공개: {title}"),
        text_body: format!("새 사건 공개가 게시되었습니다: {title}\n{url}"),
        html_body: format!(
            "<p>새 사건 공개가 게시되었습니다: {title}</p><p><a href=\"{url}\">내용 보기</a></p>"
        ),
    };
    match state.delivery.send(&message).await {
        Ok(provider_id) => {
            sqlx::query!(
                "UPDATE ops.email_deliveries SET status='DELIVERED',provider_message_id=$2, \
                 delivered_at=clock_timestamp() WHERE id=$1 AND status='SENDING'",
                delivery_id,
                provider_id,
            )
            .execute(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?;
            Ok(Some(1))
        }
        Err(_) => {
            mark_failed(state, delivery_id, "CHANNEL_DELIVERY_FAILED").await?;
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    "SMTP_DELIVERY_FAILED",
                    "publication subscriber delivery failed",
                    true,
                    serde_json::json!({"deliveryId":delivery_id}),
                )
                .await
                .map_err(WorkerError::Job)?;
            Ok(None)
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use uuid::Uuid;

    use super::{WorkerError, publication_review_snapshot_id, subscription_matches_publication};

    #[test]
    fn publication_region_binding_uses_the_event_review_snapshot() {
        let expected = Uuid::from_u128(0x00000000000040008000000000000123);

        assert_eq!(
            publication_review_snapshot_id(&json!({"reviewSnapshotId":expected})).ok(),
            Some(expected)
        );
        assert!(matches!(
            publication_review_snapshot_id(&json!({})),
            Err(WorkerError::Contract)
        ));
    }

    #[test]
    fn region_subscription_matches_exact_sigungu_code() {
        let topics = json!([{"scopeType":"REGION","scopeRef":"11680"}]);

        assert!(subscription_matches_publication(&topics, Some("11680")));
    }

    #[test]
    fn region_subscription_skips_a_different_sigungu_code() {
        let topics = json!([{"scopeType":"REGION","scopeRef":"11680"}]);

        assert!(!subscription_matches_publication(&topics, Some("11710")));
    }

    #[test]
    fn region_subscription_skips_when_publication_region_is_missing() {
        let topics = json!([{"scopeType":"REGION","scopeRef":"11680"}]);

        assert!(!subscription_matches_publication(&topics, None));
    }

    #[test]
    fn existing_subscription_scopes_keep_their_fanout_behavior() {
        for scope_type in [
            "GLOBAL",
            "QUERY",
            "CASE",
            "AGENCY",
            "SUPPLIER",
            "CORRECTIONS",
        ] {
            let topics = json!([{"scopeType":scope_type}]);
            assert!(subscription_matches_publication(&topics, None));
        }
    }
}
