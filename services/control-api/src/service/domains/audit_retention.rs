use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[path = "audit_retention_legal_hold.rs"]
mod legal_hold;
#[path = "audit_retention_privacy_correction.rs"]
mod privacy_correction;
#[path = "audit_retention_privacy_query.rs"]
mod privacy_query;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    CreateAuditExport,
    CreatePrivacyCorrectionPlan,
    PlaceLegalHold,
    ReleaseLegalHold,
    TransitionRetentionRequest,
    VerifyAuditIntegrity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetAuditExport,
    GetRetentionRequest,
    ListCaseAuditEvents,
    ListRecordClassSchedules,
    ListRetentionRequests,
    SearchAuditEvents,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "createAuditExport",
        Handler::Command(CommandHandler::AuditRetention(Command::CreateAuditExport)),
    ),
    (
        "createPrivacyCorrectionPlan",
        Handler::Command(CommandHandler::AuditRetention(
            Command::CreatePrivacyCorrectionPlan,
        )),
    ),
    (
        "getAuditExport",
        Handler::Query(QueryHandler::AuditRetention(Query::GetAuditExport)),
    ),
    (
        "getRetentionRequest",
        Handler::Query(QueryHandler::AuditRetention(Query::GetRetentionRequest)),
    ),
    (
        "listCaseAuditEvents",
        Handler::Query(QueryHandler::AuditRetention(Query::ListCaseAuditEvents)),
    ),
    (
        "listRecordClassSchedules",
        Handler::Query(QueryHandler::AuditRetention(
            Query::ListRecordClassSchedules,
        )),
    ),
    (
        "listRetentionRequests",
        Handler::Query(QueryHandler::AuditRetention(Query::ListRetentionRequests)),
    ),
    (
        "placeLegalHold",
        Handler::Command(CommandHandler::AuditRetention(Command::PlaceLegalHold)),
    ),
    (
        "releaseLegalHold",
        Handler::Command(CommandHandler::AuditRetention(Command::ReleaseLegalHold)),
    ),
    (
        "searchAuditEvents",
        Handler::Query(QueryHandler::AuditRetention(Query::SearchAuditEvents)),
    ),
    (
        "transitionRetentionRequest",
        Handler::Command(CommandHandler::AuditRetention(
            Command::TransitionRetentionRequest,
        )),
    ),
    (
        "verifyAuditIntegrity",
        Handler::Command(CommandHandler::AuditRetention(
            Command::VerifyAuditIntegrity,
        )),
    ),
];

pub(super) const fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::CreatePrivacyCorrectionPlan
        | Command::ReleaseLegalHold
        | Command::TransitionRetentionRequest => CommandKind::Addendum,
        Command::CreateAuditExport | Command::PlaceLegalHold | Command::VerifyAuditIntegrity => {
            CommandKind::Base
        }
    }
}

pub(in crate::service) fn validate_transition_request(
    payload: &Map<String, Value>,
) -> Result<(), ServiceError> {
    const COMMON_FIELDS: &[&str] = &[
        "retentionRequestId",
        "expectedDecisionVersion",
        "transition",
        "reasonCode",
        "reason",
    ];
    let retention_request_id = payload
        .get("retentionRequestId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let _ = retention_request_id;
    payload
        .get("expectedDecisionVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or(ServiceError::InvalidRequest)?;
    bounded_text(payload, "reasonCode", 100)?;
    bounded_text(payload, "reason", 10_000)?;

    let variant_fields: &[&str] =
        match string_value(payload, "transition").ok_or(ServiceError::InvalidRequest)? {
            "VERIFY_IDENTITY" => {
                payload
                    .get("identityProofReceiptId")
                    .and_then(Value::as_str)
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .filter(|value| !value.is_nil())
                    .ok_or(ServiceError::InvalidRequest)?;
                &["identityProofReceiptId"]
            }
            "START_REVIEW" | "APPROVE" => &[],
            "EXTEND" => {
                bounded_text(payload, "extensionReasonCode", 100)?;
                bounded_text(payload, "extensionReason", 4_000)?;
                payload
                    .get("extensionBusinessDays")
                    .and_then(Value::as_u64)
                    .filter(|value| (1..=i32::MAX as u64).contains(value))
                    .ok_or(ServiceError::InvalidRequest)?;
                &[
                    "extensionReasonCode",
                    "extensionReason",
                    "extensionBusinessDays",
                ]
            }
            "REJECT" => {
                bounded_text(payload, "rejectionReasonCode", 100)?;
                bounded_text(payload, "rejectionReason", 4_000)?;
                bounded_text(payload, "appealInstructions", 4_000)?;
                &[
                    "rejectionReasonCode",
                    "rejectionReason",
                    "appealInstructions",
                ]
            }
            _ => return Err(ServiceError::InvalidRequest),
        };

    if payload.keys().any(|key| {
        !COMMON_FIELDS.contains(&key.as_str()) && !variant_fields.contains(&key.as_str())
    }) || COMMON_FIELDS
        .iter()
        .any(|field| !payload.contains_key(*field))
        || variant_fields
            .iter()
            .any(|field| !payload.contains_key(*field))
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

pub(in crate::service) fn validate_correction_plan_request(
    payload: &Map<String, Value>,
) -> Result<(), ServiceError> {
    privacy_correction::validate(payload)
}

fn bounded_text(
    payload: &Map<String, Value>,
    field: &str,
    maximum_chars: usize,
) -> Result<(), ServiceError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| {
            let count = value.chars().count();
            value.trim() == *value && (1..=maximum_chars).contains(&count)
        })
        .map(|_| ())
        .ok_or(ServiceError::InvalidRequest)
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<CommandEffect, ServiceError> {
    match command {
        Command::CreateAuditExport => create_audit_export(payload, id, actor, tx)
            .await
            .map(|()| CommandEffect::none()),
        Command::PlaceLegalHold => legal_hold::place(payload, actor, tx)
            .await
            .map(CommandEffect::owner_created),
        Command::VerifyAuditIntegrity => verify_audit_integrity(payload, id, actor, tx)
            .await
            .map(|()| CommandEffect::none()),
        Command::CreatePrivacyCorrectionPlan
        | Command::ReleaseLegalHold
        | Command::TransitionRetentionRequest => Err(ServiceError::InvalidRequest),
    }
}

pub(super) async fn query(
    query: Query,
    operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetAuditExport => get_audit_export(parameters, pool).await,
        Query::GetRetentionRequest => privacy_query::get(parameters, pool).await,
        Query::ListCaseAuditEvents | Query::SearchAuditEvents => {
            audit_query(pool, parameters).await
        }
        Query::ListRetentionRequests => privacy_query::list(parameters, pool).await,
        Query::ListRecordClassSchedules => record_class_schedule_query(operation.id, pool).await,
    }
}

async fn verify_audit_integrity(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let mode = string_value(payload, "mode").ok_or(ServiceError::InvalidRequest)?;
    let from = uuid_value(payload, &["fromEventId"]);
    let to = uuid_value(payload, &["toEventId"]);
    let expected = payload.get("expectedChainHead").and_then(Value::as_str);
    match mode {
        "FULL" | "TAIL" if from.is_none() && to.is_none() => {}
        "RANGE" if from.is_some() && to.is_some() => {}
        _ => return Err(ServiceError::InvalidRequest),
    }
    if expected.is_some_and(|value| !is_sha256(value)) {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query!(
        "INSERT INTO ops.audit_verification_runs(id,mode,from_event_id,to_event_id, \
         expected_chain_head,status,requested_by) VALUES($1,$2,$3,$4,$5,'QUEUED',$6)",
        id,
        mode,
        from,
        to,
        expected,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn create_audit_export(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let seconds = payload
        .get("expiresInSeconds")
        .and_then(Value::as_i64)
        .filter(|value| (300..=86_400).contains(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let expires_at = OffsetDateTime::now_utc()
        .checked_add(time::Duration::seconds(seconds))
        .ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,object_type,object_id,reason,watermark_policy,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
        id,
        actor,
        timestamp_value(payload, "from")?.ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "to")?.ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "format").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?,
        payload.get("objectType").and_then(Value::as_str),
        payload.get("objectId").and_then(Value::as_str),
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "watermarkPolicy").ok_or(ServiceError::InvalidRequest)?,
        expires_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query!(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key) VALUES('AUDIT_EXPORT','audit-export',$1,$2)",
        json!({"auditExportId":id}),
        format!("audit-export:{id}"),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn get_audit_export(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "auditExportId")?;
    sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',id,'status',status,'format',format,'scope',scope, \
         'from',from_at,'to',to_at,'objectType',object_type,'objectId',object_id, \
         'watermarkPolicy',watermark_policy,'createdAt',created_at,'startedAt',started_at, \
         'completedAt',completed_at,'expiresAt',expires_at,'rowCount',row_count, \
         'contentSha256',content_sha256,'downloadUrl',NULL::text, \
         'failureCode',failure_code,'links','[]'::jsonb) \
         FROM ops.audit_exports WHERE id=$1",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })
}

async fn record_class_schedule_query(
    operation: &str,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    if operation != "listRecordClassSchedules" {
        return Err(ServiceError::Persistence);
    }
    let items = sqlx::query_scalar!("SELECT ops.read_record_class_schedule_queue_v1()")
        .fetch_one(pool)
        .await
        .map_err(db)?
        .ok_or_else(|| {
            db(sqlx::Error::Decode(Box::new(
                sqlx::error::UnexpectedNullError,
            )))
        })?;
    queue_page(operation, normalize_record_class_schedule_items(items))
}

fn queue_page(operation: &str, items: Value) -> Result<Value, ServiceError> {
    let as_of = format_time(OffsetDateTime::now_utc())?;
    Ok(match operation {
        "listRecordClassSchedules" => {
            json!({"items":items,"appliedRecordClasses":[],"appliedStates":[],"asOf":as_of,"nextCursor":null,"operationId":operation,"links":[]})
        }
        _ => {
            json!({"items":items,"appliedFilters":{},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]})
        }
    })
}

fn normalize_record_class_schedule_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else {
        return json!([]);
    };
    Value::Array(rows.iter().filter_map(|row| {
        Some(json!({
            "recordClass": row.get("record_class")?.clone(),
            "revision": row.get("revision").cloned().unwrap_or_else(|| json!(1)),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("CURRENT")),
            "lawfulBasis": row.get("lawful_basis").cloned().unwrap_or_else(|| json!("UNKNOWN")),
            "activeDuration": row.get("active_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "backupDuration": row.get("backup_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "terminalAction": row.get("terminal_action").cloned().unwrap_or_else(|| json!("ARCHIVE")),
            "effectiveAt": row.get("effective_at").cloned().unwrap_or(Value::Null),
            "reviewExpiresAt": row.get("review_expires_at").cloned().unwrap_or(Value::Null),
            "scheduleDigest": row.get("schedule_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000"))
        }))
    }).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn common(transition: &str) -> Map<String, Value> {
        json!({
            "retentionRequestId": "00000000-0000-4000-8000-000000000001",
            "expectedDecisionVersion": 0,
            "transition": transition,
            "reasonCode": "OPERATOR_REVIEW",
            "reason": "검증된 운영 사유"
        })
        .as_object()
        .cloned()
        .unwrap_or_default()
    }

    #[test]
    fn transition_variants_keep_exact_discriminated_shapes() {
        let mut verify = common("VERIFY_IDENTITY");
        verify.insert(
            "identityProofReceiptId".to_owned(),
            json!("00000000-0000-4000-8000-000000000002"),
        );
        assert!(validate_transition_request(&verify).is_ok());

        let mut extend = common("EXTEND");
        extend.insert("extensionReasonCode".to_owned(), json!("LARGE_SCOPE"));
        extend.insert("extensionReason".to_owned(), json!("자료 범위 확인 필요"));
        extend.insert("extensionBusinessDays".to_owned(), json!(10));
        assert!(validate_transition_request(&extend).is_ok());

        let mut reject = common("REJECT");
        reject.insert("rejectionReasonCode".to_owned(), json!("PROOF_INVALID"));
        reject.insert("rejectionReason".to_owned(), json!("제출 증빙 불일치"));
        reject.insert(
            "appealInstructions".to_owned(),
            json!("새 증빙과 함께 이의 신청"),
        );
        assert!(validate_transition_request(&reject).is_ok());

        assert!(validate_transition_request(&common("START_REVIEW")).is_ok());
        assert!(validate_transition_request(&common("APPROVE")).is_ok());
    }

    #[test]
    fn variant_fields_cannot_cross_or_exceed_authorized_limits() {
        let mut verify = common("VERIFY_IDENTITY");
        verify.insert(
            "identityProofReceiptId".to_owned(),
            json!("00000000-0000-4000-8000-000000000002"),
        );
        verify.insert("extensionBusinessDays".to_owned(), json!(10));
        assert!(matches!(
            validate_transition_request(&verify),
            Err(ServiceError::InvalidRequest)
        ));

        let mut extend = common("EXTEND");
        extend.insert("extensionReasonCode".to_owned(), json!("LARGE_SCOPE"));
        extend.insert("extensionReason".to_owned(), json!("자료 범위 확인 필요"));
        extend.insert("extensionBusinessDays".to_owned(), json!(11));
        assert!(validate_transition_request(&extend).is_ok());
        extend.insert(
            "extensionBusinessDays".to_owned(),
            json!(i64::from(i32::MAX) + 1),
        );
        assert!(matches!(
            validate_transition_request(&extend),
            Err(ServiceError::InvalidRequest)
        ));

        let mut reject = common("REJECT");
        reject.insert("rejectionReasonCode".to_owned(), json!("PROOF_INVALID"));
        reject.insert("rejectionReason".to_owned(), json!("가".repeat(4_001)));
        reject.insert("appealInstructions".to_owned(), json!("이의 신청 안내"));
        assert!(matches!(
            validate_transition_request(&reject),
            Err(ServiceError::InvalidRequest)
        ));

        assert!(matches!(
            validate_transition_request(&common("COMPLETE")),
            Err(ServiceError::InvalidRequest)
        ));
    }
}
