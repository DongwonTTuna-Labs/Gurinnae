use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    AddClaim,
    AddEvidence,
    CreateEvidenceRedaction,
    CreateHypothesis,
    LinkEvidence,
    PromoteResearchArtifactToEvidence,
    UpdateClaim,
    UpdateEvidence,
    UpdateHypothesis,
    ValidateClaims,
    VerifyEvidence,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetEvidenceWorkspace,
    ListCaseClaims,
    ListCaseEvidence,
    ListCaseHypotheses,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "addClaim",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::AddClaim)),
    ),
    (
        "addEvidence",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::AddEvidence)),
    ),
    (
        "createEvidenceRedaction",
        Handler::Command(CommandHandler::ClaimsEvidence(
            Command::CreateEvidenceRedaction,
        )),
    ),
    (
        "createHypothesis",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::CreateHypothesis)),
    ),
    (
        "getEvidenceWorkspace",
        Handler::Query(QueryHandler::ClaimsEvidence(Query::GetEvidenceWorkspace)),
    ),
    (
        "linkEvidence",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::LinkEvidence)),
    ),
    (
        "listCaseClaims",
        Handler::Query(QueryHandler::ClaimsEvidence(Query::ListCaseClaims)),
    ),
    (
        "listCaseEvidence",
        Handler::Query(QueryHandler::ClaimsEvidence(Query::ListCaseEvidence)),
    ),
    (
        "listCaseHypotheses",
        Handler::Query(QueryHandler::ClaimsEvidence(Query::ListCaseHypotheses)),
    ),
    (
        "promoteResearchArtifactToEvidence",
        Handler::Command(CommandHandler::ClaimsEvidence(
            Command::PromoteResearchArtifactToEvidence,
        )),
    ),
    (
        "updateClaim",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::UpdateClaim)),
    ),
    (
        "updateEvidence",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::UpdateEvidence)),
    ),
    (
        "updateHypothesis",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::UpdateHypothesis)),
    ),
    (
        "validateClaims",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::ValidateClaims)),
    ),
    (
        "verifyEvidence",
        Handler::Command(CommandHandler::ClaimsEvidence(Command::VerifyEvidence)),
    ),
];

pub(super) const fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::PromoteResearchArtifactToEvidence => CommandKind::Addendum,
        _ => CommandKind::Base,
    }
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    _field_keys: &EnvelopeKeyRing,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AddClaim => add_claim(payload, id, actor, transaction).await,
        Command::AddEvidence => add_evidence(payload, id, actor, transaction).await,
        Command::CreateEvidenceRedaction => {
            create_evidence_redaction(payload, id, actor, transaction).await
        }
        Command::CreateHypothesis => create_hypothesis(payload, id, actor, transaction).await,
        Command::LinkEvidence => link_evidence(payload, actor, transaction).await,
        Command::PromoteResearchArtifactToEvidence => Err(ServiceError::InvalidRequest),
        Command::UpdateClaim => update_claim(payload, transaction).await,
        Command::UpdateEvidence => update_evidence(payload, transaction).await,
        Command::UpdateHypothesis => update_hypothesis(payload, actor, transaction).await,
        Command::ValidateClaims => validate_claims(payload, transaction).await,
        Command::VerifyEvidence => verify_evidence(payload, actor, transaction).await,
    }
}

async fn add_claim(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO editorial.claims(id,case_id,claim_type,text,limitations, \
         validation_status,created_by) VALUES($1,$2,$3::editorial.claim_type,$4,$5,'DRAFT',$6)",
        id,
        case_id,
        string_value(payload, "claimType").ok_or(ServiceError::InvalidRequest)? as _,
        string_value(payload, "text").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("limitations")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    replace_claim_relations(id, payload, tx).await?;

    Ok(())
}

async fn add_evidence(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id, \
         source_url,source_locator,content_sha256,classification,verification_status, \
         description,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8, \
         $9::editorial.evidence_classification,'PENDING',$10,$11)",
        id,
        case_id,
        string_value(payload, "evidenceType").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "title").ok_or(ServiceError::InvalidRequest)?,
        uuid_value(payload, &["sourceDocumentId"]),
        payload.get("sourceUrl").and_then(Value::as_str),
        string_value(payload, "locator").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "contentHash").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "classification").ok_or(ServiceError::InvalidRequest)? as _,
        payload.get("notes").and_then(Value::as_str),
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn create_evidence_redaction(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO editorial.evidence_redactions(id,evidence_id,ranges,redaction_type, \
         reason,replacement_text,status,created_by) VALUES($1,$2,$3,$4,$5,$6,'DRAFT',$7)",
        id,
        evidence,
        payload
            .get("ranges")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "redactionType").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        payload.get("replacementText").and_then(Value::as_str),
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn create_hypothesis(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO editorial.hypotheses(id,case_id,statement,status,unknowns,created_by) \
         VALUES($1,$2,$3,'OPEN',$4,$5)",
        id,
        case_id,
        string_value(payload, "statement").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("unknowns")
            .cloned()
            .unwrap_or_else(|| json!([])),
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    replace_hypothesis_relations(id, payload, actor, tx).await?;

    Ok(())
}

async fn link_evidence(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = uuid_value(payload, &["targetId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO editorial.evidence_links(evidence_id,target_type,target_id,relation, \
         reason,created_by) VALUES($1,$2,$3,$4,$5,$6)",
        evidence,
        string_value(payload, "targetType").ok_or(ServiceError::InvalidRequest)?,
        target,
        string_value(payload, "relation").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn update_claim(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.claims SET text=COALESCE($2,text),limitations=COALESCE($3,limitations) \
         WHERE id=$1",
        claim,
        payload.get("text").and_then(Value::as_str),
        payload.get("limitations").cloned(),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    if payload.contains_key("evidenceIds") || payload.contains_key("responseIds") {
        replace_claim_relations(claim, payload, tx).await?;
    }

    Ok(())
}

async fn update_evidence(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.evidence SET title=COALESCE($2,title), \
         source_locator=COALESCE($3,source_locator), \
         classification=COALESCE($4::editorial.evidence_classification,classification), \
         description=COALESCE($5,description) WHERE id=$1",
        evidence,
        payload.get("title").and_then(Value::as_str),
        payload.get("locator").and_then(Value::as_str),
        payload.get("classification").and_then(Value::as_str) as _,
        payload.get("notes").and_then(Value::as_str),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

async fn update_hypothesis(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let hypothesis = uuid_value(payload, &["hypothesisId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE editorial.hypotheses SET statement=COALESCE($2,statement), \
         status=COALESCE($3,status),unknowns=COALESCE($4,unknowns) WHERE id=$1",
        hypothesis,
        payload.get("statement").and_then(Value::as_str),
        payload.get("status").and_then(Value::as_str),
        payload.get("unknowns").cloned(),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    if payload.contains_key("supportingEvidenceIds")
        || payload.contains_key("contradictingEvidenceIds")
    {
        replace_hypothesis_relations(hypothesis, payload, actor, tx).await?;
    }

    Ok(())
}

async fn validate_claims(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let claim = uuid_value(payload, &["claimId"]).ok_or(ServiceError::InvalidRequest)?;
    let blockers: i64 = sqlx::query_scalar!(
        "SELECT count(*) FROM editorial.claim_evidence ce \
         JOIN editorial.evidence e ON e.id=ce.evidence_id \
         WHERE ce.claim_id=$1 AND e.verification_status<>'VERIFIED'",
        claim,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    let status = if blockers == 0 { "VALID" } else { "BLOCKED" };
    let changed = sqlx::query!(
        "UPDATE editorial.claims SET validation_status=$2::core.claim_validation_status WHERE id=$1",
        claim,
        status as _,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

async fn verify_evidence(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let evidence = uuid_value(payload, &["evidenceId"]).ok_or(ServiceError::InvalidRequest)?;
    let requested =
        string_value(payload, "verificationStatus").ok_or(ServiceError::InvalidRequest)?;
    let status = match requested {
        "verified" | "VERIFIED" => "VERIFIED",
        "rejected" | "REJECTED" => "REJECTED",
        "needs_work" | "NEEDS_WORK" => "NEEDS_WORK",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let changed = sqlx::query!(
        "UPDATE editorial.evidence SET verification_status=$2,verified_by=$3, \
         verified_at=CASE WHEN $2='VERIFIED' THEN clock_timestamp() ELSE NULL END WHERE id=$1",
        evidence,
        status,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetEvidenceWorkspace => get_evidence_workspace(parameters, pool).await,
        Query::ListCaseClaims | Query::ListCaseEvidence | Query::ListCaseHypotheses => {
            case_list_query(query, parameters, pool).await
        }
    }
}

async fn get_evidence_workspace(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "evidenceId")?;
    let evidence: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',id,'caseId',case_id,'evidenceType',evidence_type, \
         'title',title,'description',description,'sourceDocumentId',source_document_id, \
         'sourceUrl',source_url,'sourceLocator',source_locator,'contentSha256',content_sha256, \
         'classification',classification::text,'verificationStatus',verification_status, \
         'verifiedBy',verified_by,'verifiedAt',verified_at,'publicExcerpt',redacted_public_excerpt, \
         'version',version) FROM editorial.evidence WHERE id=$1",
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
    })?;
    let claims: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('claimId',claim_id,'citationLabel', \
         citation_label,'citationOrder',citation_order,'supports',supports) ORDER BY citation_order), \
         '[]'::jsonb) FROM editorial.claim_evidence WHERE evidence_id=$1",
        id,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    let redactions: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'ranges',ranges,'redactionType', \
         redaction_type,'reason',reason,'replacementText',replacement_text,'status',status) \
         ORDER BY created_at),'[]'::jsonb) FROM editorial.evidence_redactions WHERE evidence_id=$1",
        id,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    Ok(
        json!({"evidence":evidence,"sourceContext":{},"linkedClaims":claims,
        "verification":{},"redactions":redactions,"provenance":{},"blockers":[]}),
    )
}

async fn case_list_query(
    query: Query,
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = match query {
        Query::ListCaseClaims => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'claimType',claim_type::text,'text',text,'limitations',limitations,'validationStatus',validation_status,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.claims WHERE case_id=$1", case_id).fetch_one(pool).await.map_err(db)?.ok_or_else(|| db(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?
        }
        Query::ListCaseEvidence => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'evidenceType',evidence_type,'title',title,'classification',classification::text,'verificationStatus',verification_status,'contentSha256',content_sha256,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.evidence WHERE case_id=$1", case_id).fetch_one(pool).await.map_err(db)?.ok_or_else(|| db(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?
        }
        Query::ListCaseHypotheses => {
            let case_id = query_uuid(parameters, "caseId")?;
            sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'caseId',case_id,'statement',statement,'status',status,'unknowns',unknowns,'version',version) ORDER BY created_at),'[]'::jsonb) FROM editorial.hypotheses WHERE case_id=$1", case_id).fetch_one(pool).await.map_err(db)?.ok_or_else(|| db(sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError))))?
        }
        Query::GetEvidenceWorkspace => return Err(ServiceError::InvalidRequest),
    };
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
