use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    ActivateRuleVersion,
    CreateRuleVersionDraft,
    RollbackRuleVersion,
    RunRuleEvaluation,
    ScheduleRuleActivation,
    StartRuleShadow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetInternalRuleVersion,
    GetRuleActivationReadiness,
    GetRuleEvaluation,
    ListInternalRules,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "activateRuleVersion",
        Handler::Command(CommandHandler::Rules(Command::ActivateRuleVersion)),
    ),
    (
        "createRuleVersionDraft",
        Handler::Command(CommandHandler::Rules(Command::CreateRuleVersionDraft)),
    ),
    (
        "getInternalRuleVersion",
        Handler::Query(QueryHandler::Rules(Query::GetInternalRuleVersion)),
    ),
    (
        "getRuleActivationReadiness",
        Handler::Query(QueryHandler::Rules(Query::GetRuleActivationReadiness)),
    ),
    (
        "getRuleEvaluation",
        Handler::Query(QueryHandler::Rules(Query::GetRuleEvaluation)),
    ),
    (
        "listInternalRules",
        Handler::Query(QueryHandler::Rules(Query::ListInternalRules)),
    ),
    (
        "rollbackRuleVersion",
        Handler::Command(CommandHandler::Rules(Command::RollbackRuleVersion)),
    ),
    (
        "runRuleEvaluation",
        Handler::Command(CommandHandler::Rules(Command::RunRuleEvaluation)),
    ),
    (
        "scheduleRuleActivation",
        Handler::Command(CommandHandler::Rules(Command::ScheduleRuleActivation)),
    ),
    (
        "startRuleShadow",
        Handler::Command(CommandHandler::Rules(Command::StartRuleShadow)),
    ),
];

pub(super) const fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::ActivateRuleVersion | Command::ScheduleRuleActivation => {
            activate_or_schedule_rule_version(operation, payload, tx).await
        }
        Command::CreateRuleVersionDraft => create_rule_version_draft(payload, id, actor, tx).await,
        Command::RollbackRuleVersion => rollback_rule_version(payload, tx).await,
        Command::RunRuleEvaluation => run_rule_evaluation(payload, id, actor, tx).await,
        Command::StartRuleShadow => start_rule_shadow(payload, actor, tx).await,
    }
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetInternalRuleVersion | Query::GetRuleActivationReadiness => {
            query_rule_version(parameters, pool).await
        }
        Query::GetRuleEvaluation => query_rule_evaluation(parameters, pool).await,
        Query::ListInternalRules => list_internal_rules(parameters, pool).await,
    }
}

async fn activate_or_schedule_rule_version(
    operation: &str,
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let version = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let digest = string_value(payload, "evaluationDigest")
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let evaluated: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_evaluations WHERE rule_version_id=$1 \
         AND status='SUCCEEDED' AND result_digest=$2)",
    )
    .bind(version)
    .bind(digest)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !evaluated {
        return Err(ServiceError::InvalidRequest);
    }
    let effective_at =
        timestamp_value(payload, "effectiveAt")?.ok_or(ServiceError::InvalidRequest)?;
    let rollout = if operation == "scheduleRuleActivation" {
        Some(string_value(payload, "rollout").ok_or(ServiceError::InvalidRequest)?)
    } else {
        Some("ALL")
    };
    if operation == "activateRuleVersion" && effective_at > OffsetDateTime::now_utc() {
        return Err(ServiceError::InvalidRequest);
    }
    if operation == "activateRuleVersion" {
        sqlx::query(
            "UPDATE core.rule_versions SET status='RETIRED',retired_at=clock_timestamp() \
             WHERE rule_id=(SELECT rule_id FROM core.rule_versions WHERE id=$1) \
               AND status='ACTIVE' AND id<>$1",
        )
        .bind(version)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    let status = if operation == "activateRuleVersion" {
        "ACTIVE"
    } else {
        "SCHEDULED"
    };
    let changed = sqlx::query(
        "UPDATE core.rule_versions SET status=$2,effective_at=$3, \
         activation_evaluation_digest=$4,activation_rollout=$5,activation_reason=$6 \
         WHERE id=$1 AND status IN ('DRAFT','SHADOW','SCHEDULED')",
    )
    .bind(version)
    .bind(status)
    .bind(effective_at)
    .bind(digest)
    .bind(rollout)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

async fn create_rule_version_draft(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule_id = string_value(payload, "ruleId").ok_or(ServiceError::InvalidRequest)?;
    let version = payload
        .get("baseVersion")
        .and_then(Value::as_str)
        .map_or_else(
            || format!("draft-{}", id.simple()),
            |base| format!("{base}-draft-{}", id.simple()),
        );
    sqlx::query(
        "INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration, \
         code_digest,status,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,'DRAFT',$8)",
    )
    .bind(id)
    .bind(rule_id)
    .bind(version)
    .bind(string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?)
    .bind(string_value(payload, "description").ok_or(ServiceError::InvalidRequest)?)
    .bind(
        payload
            .get("configuration")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(
        string_value(payload, "implementationDigest")
            .filter(|value| is_sha256(value))
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn rollback_rule_version(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let current = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = uuid_value(payload, &["targetVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let same_rule: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_versions target \
         JOIN core.rule_versions current ON current.id=$1 \
         WHERE target.id=$2 AND target.rule_id=current.rule_id \
           AND target.status IN ('RETIRED','ROLLED_BACK','ACTIVE'))",
    )
    .bind(current)
    .bind(target)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !same_rule {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "UPDATE core.rule_versions SET status='ROLLED_BACK',retired_at=clock_timestamp(), \
         activation_reason=$2 WHERE id=$1",
    )
    .bind(current)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query(
        "UPDATE core.rule_versions SET status='ACTIVE',effective_at=clock_timestamp(), \
         retired_at=NULL WHERE id=$1",
    )
    .bind(target)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn run_rule_evaluation(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let dataset =
        uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
         evaluation_profile,status,requested_by,reason) \
         VALUES($1,$2,$3,$4,'QUEUED',$5,$6)",
    )
    .bind(id)
    .bind(rule)
    .bind(dataset)
    .bind(string_value(payload, "evaluationProfile").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "RULE_EVALUATION",
        "analysis-worker",
        json!({"evaluationId":id}),
        format!("rule-evaluation:{id}"),
    )
    .await?;

    Ok(())
}

async fn start_rule_shadow(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let rule = uuid_value(payload, &["ruleVersionId"]).ok_or(ServiceError::InvalidRequest)?;
    let dataset =
        uuid_value(payload, &["datasetSnapshotId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE core.rule_versions SET status='SHADOW',activation_reason=$2 \
         WHERE id=$1 AND status='DRAFT'",
    )
    .bind(rule)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    let evaluation_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id, \
         evaluation_profile,status,requested_by,reason) \
         VALUES($1,$2,$3,'SHADOW','QUEUED',$4,$5)",
    )
    .bind(evaluation_id)
    .bind(rule)
    .bind(dataset)
    .bind(actor)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "RULE_EVALUATION",
        "analysis-worker",
        json!({"evaluationId":evaluation_id}),
        format!("rule-evaluation:{evaluation_id}"),
    )
    .await?;

    Ok(())
}

async fn query_rule_version(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "ruleVersionId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'ruleId',rule_id,'versionName',version,'name',name, \
         'description',description,'configuration',configuration,'implementationDigest',code_digest, \
         'status',status,'effectiveAt',effective_at,'retiredAt',retired_at,'rowVersion',row_version, \
         'evaluationDigest',activation_evaluation_digest,'rollout',activation_rollout, \
         'activationReason',activation_reason) FROM core.rule_versions WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn query_rule_evaluation(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "evaluationRunId")?;
    let row: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'ruleVersionId',rule_version_id, \
         'datasetSnapshotId',dataset_snapshot_id,'evaluationProfile',evaluation_profile, \
         'status',status,'result',result_payload,'resultDigest',result_digest, \
         'reason',reason,'startedAt',started_at,'completedAt',completed_at) \
         FROM core.rule_evaluations WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn list_internal_rules(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'ruleId',rule_id,'versionName',version,'name',name,'status',status,'effectiveAt',effective_at,'rowVersion',row_version) ORDER BY rule_id,created_at DESC),'[]'::jsonb) FROM core.rule_versions").fetch_one(pool).await.map_err(db)?;
    let response = json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?});
    Ok(response)
}
