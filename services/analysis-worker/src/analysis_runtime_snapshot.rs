use super::{Failure, ProviderTurnIdentity, State, canonical_bytes, database, required, sha256};
use gurine_agent_orchestration::research::{
    ResearchRequestKind as StoredResearchRequestKind, Sha256Digest,
};
use gurine_agent_orchestration::runtime::{
    ComparableRecord, EntityIdentifier, EntityIdentifierKind, EntityRecord, EvidenceRecord,
    ResponseRecord, RuleRecord, SnapshotBinding, SourceArtifactRecord, SourceRequestKind, ToolCall,
    ToolRequest, ToolSnapshot,
};
use gurine_object_store::gateway::GatewayObjectStore;
use gurine_persistence_postgres::research_artifacts::ResearchArtifactRepository;
use sqlx::{Postgres, Transaction};

#[path = "analysis_corpus_snapshot.rs"]
mod corpus;
#[path = "analysis_runtime_snapshot_binding.rs"]
mod snapshot_binding;

use snapshot_binding::RuntimeSnapshotContract;

pub(super) async fn load_tool_snapshot(
    state: &State,
    turn: &ProviderTurnIdentity,
    binding: SnapshotBinding,
    tool_call: Option<&ToolCall>,
) -> Result<ToolSnapshot, Failure> {
    let mut transaction = state.pool.begin().await.map_err(database)?;
    sqlx::query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .execute(&mut *transaction)
        .await
        .map_err(database)?;
    let validated = snapshot_binding::validate(&mut transaction, turn, &binding).await?;
    let contract = validated.contract;
    let evidence =
        evidence_records(&mut transaction, turn, contract, binding.input_snapshot_id).await?;
    let responses =
        load_responses(&mut transaction, turn, contract, binding.input_snapshot_id).await?;
    let comparables =
        load_comparables(&mut transaction, turn, contract, binding.input_snapshot_id).await?;
    let entities =
        load_entities(&mut transaction, turn, contract, binding.input_snapshot_id).await?;
    let rules = load_rules(&mut transaction, turn, contract).await?;
    let mut typed_relationship_query_digest = None;
    let (contracts, supplier_profiles, agency_profiles, relationships, typed_relationships) =
        if contract == RuntimeSnapshotContract::V2 {
            let typed_relationship_request = match tool_call {
                Some(
                    call @ ToolCall {
                        request: ToolRequest::RelationshipNeighborsV3(request),
                        ..
                    },
                ) => {
                    let canonical = canonical_bytes(&call.request_wire)?;
                    typed_relationship_query_digest = Some(sha256(&canonical));
                    Some(corpus::TypedRelationshipRequest {
                        canonical,
                        limit: i64::from(request.limit),
                        snapshot_generation: validated.producer_generation,
                    })
                }
                _ => None,
            };
            let snapshot = corpus::load(
                &mut transaction,
                turn,
                binding.input_snapshot_id,
                typed_relationship_request,
            )
            .await?;
            (
                snapshot.contracts,
                snapshot.supplier_profiles,
                snapshot.agency_profiles,
                snapshot.relationships,
                snapshot.typed_relationships,
            )
        } else {
            (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new())
        };
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
        contracts,
        supplier_profiles,
        agency_profiles,
        relationships,
        typed_relationships,
        typed_relationship_query_digest,
        source_artifacts,
    })
}

async fn load_responses(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    contract: RuntimeSnapshotContract,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<Vec<ResponseRecord>, Failure> {
    let require_v2_binding = contract == RuntimeSnapshotContract::V2;
    sqlx::query!(
        "SELECT DISTINCT source_use.response_id,source_use.response_content_sha256
           FROM ops.agent_source_uses source_use
           LEFT JOIN core.dataset_snapshot_members member
             ON member.id=source_use.snapshot_member_id AND member.dataset_snapshot_id=source_use.dataset_snapshot_id
            AND member.member_digest=source_use.snapshot_member_digest
           LEFT JOIN core.dataset_snapshot_member_sources member_source
             ON member_source.id=source_use.snapshot_member_source_id AND member_source.dataset_snapshot_id=member.dataset_snapshot_id
            AND member_source.snapshot_member_id=member.id
            AND member_source.snapshot_member_digest=member.member_digest
          WHERE source_use.agent_run_id=$1
            AND source_use.response_id IS NOT NULL AND source_use.response_content_sha256 IS NOT NULL
            AND (NOT $3 OR (
              source_use.dataset_snapshot_id=$2 AND source_use.source_kind='RESPONSE_SNAPSHOT'
              AND member.object_type='RESPONSE' AND member.response_id=source_use.response_id
              AND member.object_version=source_use.response_version
              AND member.object_content_sha256=source_use.response_content_sha256
              AND member_source.source_kind='RESPONSE' AND member_source.response_id=source_use.response_id
              AND member_source.response_version=source_use.response_version
              AND member_source.response_content_sha256=source_use.response_content_sha256
            ))
          ORDER BY source_use.response_id",
        turn.run_id,
        dataset_snapshot_id,
        require_v2_binding,
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
    contract: RuntimeSnapshotContract,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<Vec<ComparableRecord>, Failure> {
    let require_v2_binding = contract == RuntimeSnapshotContract::V2;
    sqlx::query!(
        "SELECT DISTINCT source_use.object_id,source_use.source_use_id
           FROM ops.agent_source_uses source_use
           LEFT JOIN core.dataset_snapshot_members member
             ON member.id=source_use.snapshot_member_id AND member.dataset_snapshot_id=source_use.dataset_snapshot_id
            AND member.member_digest=source_use.snapshot_member_digest
           LEFT JOIN core.dataset_snapshot_member_sources member_source
             ON member_source.id=source_use.snapshot_member_source_id AND member_source.dataset_snapshot_id=member.dataset_snapshot_id
            AND member_source.snapshot_member_id=member.id
            AND member_source.snapshot_member_digest=member.member_digest
          WHERE source_use.agent_run_id=$1 AND source_use.object_type='CONTRACT'
            AND source_use.object_id IS NOT NULL
            AND (NOT $3 OR (
              source_use.dataset_snapshot_id=$2 AND source_use.source_kind='DATASET_MEMBER'
              AND member.object_type='CONTRACT' AND member.object_id=source_use.object_id
              AND member.object_version=source_use.object_version
              AND member.object_content_sha256=source_use.object_content_sha256
              AND member_source.source_digest=source_use.snapshot_member_source_digest
            ))
          ORDER BY source_use.object_id,source_use.source_use_id",
        turn.run_id,
        dataset_snapshot_id,
        require_v2_binding,
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
    contract: RuntimeSnapshotContract,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<Vec<EntityRecord>, Failure> {
    match contract {
        RuntimeSnapshotContract::V1 => load_legacy_entities(executor, turn).await,
        RuntimeSnapshotContract::V2 => {
            load_v2_snapshot_entities(executor, turn, dataset_snapshot_id).await
        }
    }
}

async fn load_legacy_entities(
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

async fn load_v2_snapshot_entities(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<Vec<EntityRecord>, Failure> {
    sqlx::query!(
        "SELECT member.object_type,member.object_id,member.canonical_payload
           FROM core.dataset_snapshot_members member
          WHERE member.dataset_snapshot_id=$1
            AND member.object_type IN ('AGENCY','SUPPLIER')
            AND EXISTS(
              SELECT 1 FROM ops.agent_source_uses source_use
               WHERE source_use.agent_run_id=$2
                 AND source_use.use_kind='TOOL_QUERY'
                 AND source_use.source_kind='DATASET_MEMBER'
                 AND source_use.dataset_snapshot_id=member.dataset_snapshot_id
                 AND source_use.snapshot_member_id=member.id
                 AND source_use.snapshot_member_digest=member.member_digest
                 AND source_use.object_type=member.object_type
                 AND source_use.object_id=member.object_id
                 AND source_use.object_version=member.object_version
                 AND source_use.object_content_sha256=member.object_content_sha256
            )
          ORDER BY member.member_ordinal,member.id",
        dataset_snapshot_id,
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| snapshot_entity(row.object_id, &row.canonical_payload))
    .collect()
}

fn snapshot_entity(
    entity_id: uuid::Uuid,
    canonical_payload: &serde_json::Value,
) -> Result<EntityRecord, Failure> {
    let canonical_name = canonical_payload
        .get("canonicalName")
        .and_then(serde_json::Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| {
            Failure::Terminal("AGENT_CORPUS_SNAPSHOT_INVALID", "canonicalName".to_owned())
        })?;
    let mut identifiers = vec![EntityIdentifier {
        kind: EntityIdentifierKind::CanonicalName,
        value: canonical_name.clone(),
    }];
    if let Some(aliases) = canonical_payload.get("verifiedAliases") {
        let aliases = aliases.as_array().ok_or_else(|| {
            Failure::Terminal(
                "AGENT_CORPUS_SNAPSHOT_INVALID",
                "verifiedAliases".to_owned(),
            )
        })?;
        for alias in aliases {
            let alias = alias
                .as_str()
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| {
                    Failure::Terminal(
                        "AGENT_CORPUS_SNAPSHOT_INVALID",
                        "verifiedAliases".to_owned(),
                    )
                })?;
            identifiers.push(EntityIdentifier {
                kind: EntityIdentifierKind::VerifiedAlias,
                value: alias.to_owned(),
            });
        }
    }
    Ok(EntityRecord {
        entity_id,
        canonical_name,
        identifiers,
    })
}

async fn load_rules(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    contract: RuntimeSnapshotContract,
) -> Result<Vec<RuleRecord>, Failure> {
    if contract == RuntimeSnapshotContract::V2 {
        // RULE_RUN is not an AGENT_CASE DatasetSnapshot member kind. A v2
        // runtime may expose one only after a typed, source-use-bound tool
        // response is implemented; querying the live rule table here would
        // create a second scope authority.
        return Ok(Vec::new());
    }
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
    let snapshot_sha256 = Sha256Digest::parse(&turn.input_snapshot_sha256).map_err(|_| {
        Failure::Terminal(
            "SOURCE_ARTIFACT_INVALID",
            "input_snapshot_sha256".to_owned(),
        )
    })?;
    let rows = ResearchArtifactRepository::new()
        .list_runtime_capsules(&mut **executor, turn.run_id, &snapshot_sha256)
        .await?;
    let mut artifacts = Vec::with_capacity(rows.len());
    for row in rows {
        let content_sha256 = row.content_sha256.as_str().to_owned();
        let object_key = row.object_key;
        let request_kind = match row.request_kind {
            StoredResearchRequestKind::SearchPublicWeb => SourceRequestKind::SearchPublicWeb,
            StoredResearchRequestKind::FetchUrl => SourceRequestKind::FetchUrl,
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
            fetch_receipt_sha256: row.artifact_sha256.as_str().to_owned(),
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
    contract: RuntimeSnapshotContract,
    dataset_snapshot_id: uuid::Uuid,
) -> Result<Vec<EvidenceRecord>, Failure> {
    let require_v2_binding = contract == RuntimeSnapshotContract::V2;
    sqlx::query!(
        "SELECT COALESCE(
                  source_use.evidence_segment_id,
                  source_use.research_artifact_id,
                  legacy_evidence.id
                ) AS id,
                source_use.source_use_id,
                btrim(source_use.source_use_sha256::text) AS source_use_sha,
                btrim(source_use.selected_content_sha256::text) AS selected_sha,
                COALESCE(source_use.locator_value,legacy_evidence.source_locator) AS locator
           FROM ops.agent_source_uses source_use
           LEFT JOIN core.dataset_snapshot_members member
             ON member.id=source_use.snapshot_member_id
            AND member.dataset_snapshot_id=source_use.dataset_snapshot_id
            AND member.member_digest=source_use.snapshot_member_digest
           LEFT JOIN core.dataset_snapshot_member_sources member_source
             ON member_source.id=source_use.snapshot_member_source_id
            AND member_source.dataset_snapshot_id=member.dataset_snapshot_id
            AND member_source.snapshot_member_id=member.id
            AND member_source.snapshot_member_digest=member.member_digest
           LEFT JOIN editorial.evidence legacy_evidence
             ON NOT $3
            AND source_use.source_kind='DATASET_MEMBER'
            AND legacy_evidence.source_document_id=source_use.source_document_id
            AND legacy_evidence.verification_status='VERIFIED'
          WHERE source_use.agent_run_id=$1
            AND source_use.use_kind IN ('TOOL_QUERY','TOOL_RESULT','MODEL_INPUT')
            AND source_use.selected_content_sha256 IS NOT NULL
            AND source_use.locator_value IS NOT NULL
            AND (
              source_use.source_kind='RESEARCH_ARTIFACT'
              OR (source_use.source_kind='EVIDENCE_SEGMENT'
                  AND source_use.evidence_segment_id IS NOT NULL
                  AND (NOT $3 OR (
                    source_use.dataset_snapshot_id=$2
                    AND member.object_type='EVIDENCE_SEGMENT'
                    AND member.evidence_segment_id=source_use.evidence_segment_id
                    AND member.object_id=source_use.evidence_segment_id
                    AND member.object_version=source_use.object_version
                    AND member.object_content_sha256=source_use.object_content_sha256
                    AND member_source.source_kind='SOURCE_DOCUMENT'
                    AND member_source.evidence_segment_id=source_use.evidence_segment_id
                    AND member_source.source_digest=source_use.snapshot_member_source_digest
                  )))
              OR (NOT $3 AND source_use.source_kind='DATASET_MEMBER'
                  AND legacy_evidence.id IS NOT NULL)
            )
          ORDER BY 1,2",
        turn.run_id,
        dataset_snapshot_id,
        require_v2_binding,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(EvidenceRecord {
            evidence_id: required(row.id).map_err(database)?,
            source_use_id: row.source_use_id,
            source_use_sha256: required(row.source_use_sha).map_err(database)?,
            selected_content_sha256: required(row.selected_sha).map_err(database)?,
            locator: required(row.locator).map_err(database)?,
        })
    })
    .collect()
}
