use super::{Failure, ProviderTurnIdentity, State, database, required};
use gurine_agent_orchestration::runtime::{
    ComparableRecord, EntityIdentifier, EntityIdentifierKind, EntityRecord, EvidenceRecord,
    ResponseRecord, RuleRecord, SnapshotBinding, SourceArtifactRecord, SourceRequestKind,
    ToolSnapshot,
};
use gurine_object_store::gateway::GatewayObjectStore;
use sqlx::{Postgres, Transaction};

pub(super) async fn load_tool_snapshot(
    state: &State,
    turn: &ProviderTurnIdentity,
    binding: SnapshotBinding,
) -> Result<ToolSnapshot, Failure> {
    let mut transaction = state.pool.begin().await.map_err(database)?;
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .execute(&mut *transaction)
        .await
        .map_err(database)?;
    let snapshot_bound: bool = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM core.dataset_snapshots ds
            WHERE ds.id=$1 AND ds.snapshot_sha256=CAST($2 AS char(64)) AND ds.state='READY')
         AND NOT EXISTS(SELECT 1 FROM ops.agent_source_uses su
            WHERE su.agent_run_id=$3 AND su.dataset_snapshot_id IS NOT NULL
              AND su.dataset_snapshot_id<>$1)",
        binding.input_snapshot_id,
        &binding.input_snapshot_sha256,
        turn.run_id,
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        database(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })?;
    if !snapshot_bound {
        return Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            "input snapshot binding".to_owned(),
        ));
    }
    let evidence = evidence_records(&mut transaction, turn).await?;
    let responses = load_responses(&mut transaction, turn).await?;
    let comparables = load_comparables(&mut transaction, turn).await?;
    let entities = load_entities(&mut transaction, turn).await?;
    let rules = load_rules(&mut transaction, turn).await?;
    let source_artifacts =
        load_source_artifacts(&mut transaction, turn, state.object_store.as_ref()).await?;
    transaction.commit().await.map_err(database)?;
    Ok(ToolSnapshot {
        binding,
        evidence,
        responses,
        comparables,
        entities,
        rules,
        source_artifacts,
    })
}

async fn load_responses(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
) -> Result<Vec<ResponseRecord>, Failure> {
    sqlx::query!(
        "SELECT DISTINCT response_id,response_content_sha256
           FROM ops.agent_source_uses
          WHERE agent_run_id=$1 AND response_id IS NOT NULL
            AND response_content_sha256 IS NOT NULL
          ORDER BY response_id",
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(ResponseRecord {
            response_id: required(row.response_id).map_err(database)?,
            response_content_sha256: required(row.response_content_sha256).map_err(database)?,
        })
    })
    .collect()
}

async fn load_comparables(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
) -> Result<Vec<ComparableRecord>, Failure> {
    sqlx::query!(
        "SELECT DISTINCT object_id,source_use_id
           FROM ops.agent_source_uses
          WHERE agent_run_id=$1 AND object_type='CONTRACT'
            AND object_id IS NOT NULL
          ORDER BY object_id,source_use_id",
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(ComparableRecord {
            contract_id: required(row.object_id).map_err(database)?,
            source_use_id: row.source_use_id,
        })
    })
    .collect()
}

async fn load_entities(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
) -> Result<Vec<EntityRecord>, Failure> {
    let rows = sqlx::query!(
        "SELECT DISTINCT object_type,object_id,
                CASE WHEN object_type='AGENCY' THEN (SELECT canonical_name FROM core.agencies WHERE id=s.object_id)
                     WHEN object_type='SUPPLIER' THEN (SELECT canonical_name FROM core.suppliers WHERE id=s.object_id)
                END AS canonical_name
           FROM ops.agent_source_uses s
          WHERE agent_run_id=$1 AND object_type IN ('AGENCY','SUPPLIER')
            AND object_id IS NOT NULL
          ORDER BY object_id",
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?;
    let mut entities = rows
        .into_iter()
        .map(|row| {
            let id = required(row.object_id).map_err(database)?;
            let name = row.canonical_name.unwrap_or_else(|| id.to_string());
            Ok((
                id,
                EntityRecord {
                    entity_id: id,
                    canonical_name: name.clone(),
                    identifiers: vec![EntityIdentifier {
                        kind: EntityIdentifierKind::CanonicalName,
                        value: name,
                    }],
                },
            ))
        })
        .collect::<Result<std::collections::BTreeMap<_, _>, Failure>>()?;
    if !entities.is_empty() {
        let ids = entities.keys().copied().collect::<Vec<_>>();
        let aliases = sqlx::query!(
            "SELECT entity_id,alias FROM core.entity_aliases
              WHERE entity_id = ANY($1) ORDER BY entity_id,alias",
            &ids,
        )
        .fetch_all(&mut **executor)
        .await
        .map_err(database)?;
        for row in aliases {
            let id = row.entity_id;
            if let Some(entity) = entities.get_mut(&id) {
                entity.identifiers.push(EntityIdentifier {
                    kind: EntityIdentifierKind::VerifiedAlias,
                    value: row.alias,
                });
            }
        }
    }
    Ok(entities.into_values().collect())
}

async fn load_rules(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
) -> Result<Vec<RuleRecord>, Failure> {
    sqlx::query!(
        "SELECT rr.id AS rule_run_id,rr.rule_version_id,
                COALESCE(rr.input_digest::text,
                  encode(extensions.digest(convert_to(COALESCE(rr.error_detail,''),'UTF8'),'sha256'),'hex')) AS result_digest
           FROM core.rule_runs rr
          WHERE rr.status='SUCCEEDED'
            AND EXISTS (SELECT 1 FROM ops.agent_source_uses s
                         WHERE s.agent_run_id=$1 AND s.object_type='RULE_RUN'
                           AND s.object_id=rr.id)
          ORDER BY rr.id",
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(RuleRecord {
            rule_run_id: row.rule_run_id,
            rule_version_id: row.rule_version_id,
            result_digest: required(row.result_digest).map_err(database)?,
        })
    })
    .collect()
}

async fn load_source_artifacts(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    object_store: Option<&GatewayObjectStore>,
) -> Result<Vec<SourceArtifactRecord>, Failure> {
    let rows = sqlx::query!(
        "SELECT r.id AS research_artifact_id,
                su.source_use_id,r.content_sha256,r.artifact_sha256,r.content_media_type,
                r.request_kind,r.source_url_redacted,r.final_url_redacted,r.object_key
           FROM raw.research_artifacts r
           JOIN LATERAL (
             SELECT source_use_id FROM ops.agent_source_uses
              WHERE agent_run_id=r.agent_run_id AND research_artifact_id=r.id
                AND use_kind='TOOL_RESULT'
              ORDER BY source_use_id LIMIT 1
           ) su ON true
          WHERE r.agent_run_id=$1 AND r.input_snapshot_sha256=CAST($2 AS char(64)) AND r.fetch_outcome='STORED'
          ORDER BY r.id",
        turn.run_id,
        &turn.input_snapshot_sha256,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?;
    let mut artifacts = Vec::with_capacity(rows.len());
    for row in rows {
        let content_sha256 = row.content_sha256;
        let object_key = row.object_key;
        let request_kind = match row.request_kind.as_str() {
            "SEARCH_PUBLIC_WEB" => SourceRequestKind::SearchPublicWeb,
            "FETCH_URL" => SourceRequestKind::FetchUrl,
            _ => {
                return Err(Failure::Terminal(
                    "SOURCE_ARTIFACT_INVALID",
                    "request_kind".to_owned(),
                ));
            }
        };
        // Search results are discovery-only in the closed tool response and
        // must not cause an object-store read.  FETCH_URL is the only branch
        // whose response carries materialized bytes and therefore performs a
        // strict expected-SHA read.
        let content_bytes = if request_kind == SourceRequestKind::FetchUrl {
            match object_store {
                Some(store) => Some(
                    store
                        .get(&object_key, Some(&content_sha256))
                        .await
                        .map_err(|_| {
                            Failure::Terminal("OBJECT_STORE_READ_FAILED", object_key.clone())
                        })?,
                ),
                None => None,
            }
        } else {
            None
        };
        artifacts.push(SourceArtifactRecord {
            research_artifact_id: row.research_artifact_id,
            source_use_id: row.source_use_id,
            content_sha256,
            fetch_receipt_sha256: row.artifact_sha256,
            content_media_type: row.content_media_type,
            request_kind,
            source_url: row.source_url_redacted,
            final_url: row.final_url_redacted,
            content_bytes,
        });
    }
    Ok(artifacts)
}

async fn evidence_records(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
) -> Result<Vec<EvidenceRecord>, Failure> {
    sqlx::query!(
        "SELECT e.id,su.source_use_id,btrim(su.source_use_sha256::text) AS source_use_sha,
                btrim(su.selected_content_sha256::text) AS selected_sha,
                COALESCE(su.locator_value,e.source_locator) AS locator
           FROM editorial.evidence e
           JOIN ops.agent_source_uses su ON su.agent_run_id=$1
             AND su.use_kind='TOOL_QUERY' AND su.source_kind='DATASET_MEMBER'
             AND EXISTS (SELECT 1 FROM core.dataset_snapshots ds
                           WHERE ds.id=su.dataset_snapshot_id
                             AND ds.snapshot_sha256=CAST($2 AS char(64)) AND ds.state='READY')
          WHERE e.verification_status='VERIFIED' AND su.selected_content_sha256 IS NOT NULL
         UNION ALL
         SELECT su.research_artifact_id AS id,su.source_use_id,btrim(su.source_use_sha256::text),
                btrim(su.selected_content_sha256::text),su.locator_value
           FROM ops.agent_source_uses su
          WHERE su.agent_run_id=$1
            AND su.use_kind IN ('TOOL_QUERY','TOOL_RESULT','MODEL_INPUT')
            AND su.source_kind='RESEARCH_ARTIFACT'
            AND su.research_artifact_id IS NOT NULL
            AND su.selected_content_sha256 IS NOT NULL
          ORDER BY 1,2",
        turn.run_id,
        &turn.input_snapshot_sha256,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(EvidenceRecord {
            evidence_id: required(row.id).map_err(database)?,
            source_use_id: required(row.source_use_id).map_err(database)?,
            source_use_sha256: required(row.source_use_sha).map_err(database)?,
            selected_content_sha256: required(row.selected_sha).map_err(database)?,
            locator: required(row.locator).map_err(database)?,
        })
    })
    .collect()
}
