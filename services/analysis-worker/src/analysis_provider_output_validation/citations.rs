use super::*;

pub(super) fn resolve_citations(
    payload: &Value,
    output: &Value,
) -> Result<Vec<(usize, Value, String)>, Failure> {
    let output_citations = output
        .get("citations")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("AGENT_OUTPUT_INVALID", "citations".to_owned()))?;
    let mut references = Vec::new();
    for key in [
        "citationIndexes",
        "supportingCitationIndexes",
        "contradictingCitationIndexes",
        "citationRefs",
        "citations",
    ] {
        if let Some(value) = payload.get(key) {
            let items = value.as_array().ok_or_else(|| {
                Failure::Terminal("AGENT_OUTPUT_INVALID", format!("{key} must be an array"))
            })?;
            references.extend(items.iter().cloned());
        }
    }
    if let Some(items) = payload.get("citationIds").or_else(|| {
        payload
            .get("payload")
            .and_then(|value| value.get("citationIds"))
    }) {
        let items = items.as_array().ok_or_else(|| {
            Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                "citationIds must be an array".to_owned(),
            )
        })?;
        for id in items {
            let id = id.as_str().ok_or_else(|| {
                Failure::Terminal("AGENT_OUTPUT_INVALID", "citationId".to_owned())
            })?;
            references.push(output_citation(output, id).ok_or_else(|| {
                Failure::Terminal("AGENT_OUTPUT_INVALID", format!("unknown citationId: {id}"))
            })?);
        }
    }
    if references.is_empty() {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "proposal citation missing".to_owned(),
        ));
    }
    let mut seen = std::collections::BTreeSet::new();
    references
        .into_iter()
        .enumerate()
        .map(|(ordinal, reference)| {
            let citation = resolve_reference(&reference, output_citations)?;
            let source = citation_source(&citation)?.to_owned();
            if !seen.insert(source.to_ascii_lowercase()) {
                return Err(Failure::Terminal(
                    "AGENT_OUTPUT_INVALID",
                    "duplicate citation".to_owned(),
                ));
            }
            Ok((ordinal, citation, source))
        })
        .collect()
}

fn resolve_reference(reference: &Value, citations: &[Value]) -> Result<Value, Failure> {
    let citation = if let Some(index) = reference.as_u64() {
        citations
            .get(usize::try_from(index).map_err(|_| {
                Failure::Terminal("AGENT_OUTPUT_INVALID", "citation index".to_owned())
            })?)
            .cloned()
            .ok_or_else(|| {
                Failure::Terminal(
                    "AGENT_OUTPUT_INVALID",
                    format!("citation index out of range: {index}"),
                )
            })?
    } else if let Some(value) = reference.as_str() {
        json!({"sourceUseSha256": value})
    } else {
        reference.clone()
    };
    if !citation.is_object() {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "citation object".to_owned(),
        ));
    }
    Ok(citation)
}

fn citation_source(citation: &Value) -> Result<&str, Failure> {
    let source = citation
        .get("sourceUseSha256")
        .and_then(Value::as_str)
        .or_else(|| citation.get("source_use_sha256").and_then(Value::as_str))
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| {
            Failure::Terminal(
                "AGENT_OUTPUT_INVALID",
                "citation sourceUseSha256".to_owned(),
            )
        })?;
    if citation.get("supports").and_then(Value::as_str).is_none()
        || (citation
            .get("supportsSha256")
            .and_then(Value::as_str)
            .is_none()
            && citation
                .get("supports_sha256")
                .and_then(Value::as_str)
                .is_none())
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "citation supports".to_owned(),
        ));
    }
    Ok(source)
}

#[expect(
    clippy::too_many_arguments,
    reason = "citation persistence binds the complete provider turn, proposal, source-use, and payload provenance"
)]
pub(super) async fn persist_citation(
    executor: &mut sqlx::PgConnection,
    turn: &ProviderTurnIdentity,
    validation_id: Uuid,
    proposal_id: Uuid,
    proposal_type: &str,
    ordinal: usize,
    supports: Option<&str>,
    payload_sha256: &str,
    source_use_sha256: &str,
    citation_id: Option<Uuid>,
) -> Result<(), Failure> {
    let ordinal = i32::try_from(ordinal)
        .map_err(|_| Failure::Terminal("AGENT_OUTPUT_INVALID", "citation ordinal".to_owned()))?;
    let eligibility = citation_eligibility(proposal_type)?;
    let result = sqlx::query!(
        r#"INSERT INTO ops.agent_proposal_citations(
          citation_id,proposal_id,agent_run_id,provider_turn_id,validation_id,dataset_snapshot_id,snapshot_member_id,snapshot_member_digest,
          citation_ordinal,input_snapshot_sha256,proposal_payload_sha256,source_kind,source_use_id,source_use_sha256,
          evidence_segment_id,research_artifact_id,source_id,locator_kind,locator_value,locator_digest,content_sha256,supports_redacted,supports_sha256,citation_digest)
         SELECT COALESCE($12::uuid,gen_random_uuid()),$1::uuid,s.agent_run_id,s.provider_turn_id,$2::uuid,COALESCE(s.dataset_snapshot_id,$13::uuid),s.snapshot_member_id,s.snapshot_member_digest,$3::int4,
                $4,CAST($5 AS char(64)),CASE WHEN s.source_kind='RESEARCH_ARTIFACT' THEN 'RUN_TOOL_ARTIFACT' ELSE s.source_kind END,
                s.source_use_id,s.source_use_sha256,s.evidence_segment_id,s.research_artifact_id,
                COALESCE(s.source_document_id,s.research_artifact_id),s.locator_kind,s.locator_value,
                s.locator_sha256,s.selected_content_sha256,$6,encode(extensions.digest(convert_to($6,'UTF8'),'sha256'),'hex'),
                encode(extensions.digest(convert_to(($1::uuid)::text||':'||($3::int4)::text||':'||s.source_use_sha256,'UTF8'),'sha256'),'hex')
           FROM ops.agent_source_uses s WHERE s.agent_run_id=$7 AND s.use_kind='CITATION'
            AND s.parent_source_use_sha256=CAST($8 AS char(64))
            AND s.locator_kind IS NOT NULL AND s.locator_value IS NOT NULL AND s.locator_sha256 IS NOT NULL
            AND s.selected_content_sha256 IS NOT NULL
            AND EXISTS (SELECT 1 FROM ops.agent_suggestions proposal
                         WHERE proposal.id=$1::uuid AND proposal.agent_run_id=$7::uuid
                           AND proposal.suggestion_type=$9)
            AND ((s.source_kind='EVIDENCE_SEGMENT' AND (
                   s.classification='PUBLIC'
                   OR ($10 AND s.classification='INTERNAL')
                 )) OR ($11 AND EXISTS (
              SELECT 1 FROM raw.research_artifacts artifact
              JOIN LATERAL (
                SELECT tier.review_tier,tier.reviewed_classification
                  FROM raw.research_artifact_review_tiers tier
                 WHERE tier.research_artifact_id=artifact.id
                   AND tier.research_asset_id=artifact.asset_id
                   AND tier.research_asset_revision=artifact.asset_revision
                   AND tier.research_artifact_sha256=artifact.artifact_sha256
                   AND tier.research_content_sha256=artifact.content_sha256
                 ORDER BY tier.revision DESC LIMIT 1
              ) latest ON true
               WHERE artifact.id=s.research_artifact_id
                 AND artifact.agent_run_id=s.agent_run_id
                 AND artifact.asset_id=s.research_asset_id
                 AND artifact.asset_revision=s.research_asset_revision
                 AND artifact.artifact_sha256=s.research_artifact_sha256
                 AND artifact.content_sha256=s.research_content_sha256
                 AND artifact.source_fetch_id=s.research_source_fetch_id
                 AND latest.review_tier='OFFICIAL_UNREVIEWED'
                 AND latest.reviewed_classification='RESTRICTED'
            ))) LIMIT 1
         ON CONFLICT (proposal_id,citation_ordinal) DO NOTHING"#,
        proposal_id,
        validation_id,
        ordinal,
        &turn.input_snapshot_sha256,
        payload_sha256,
        supports,
        turn.run_id,
        source_use_sha256,
        proposal_type,
        eligibility.internal_evidence,
        eligibility.official_unreviewed_artifact,
        citation_id,
        turn.dataset_snapshot_id,
    )
    .execute(&mut *executor)
    .await
    .map_err(database)?;
    if result.rows_affected() == 1 {
        return Ok(());
    }
    let replayed = sqlx::query_scalar!(
        r#"SELECT EXISTS(
          SELECT 1 FROM ops.agent_proposal_citations citation
           WHERE citation.proposal_id=$1 AND citation.validation_id=$2
             AND citation.citation_ordinal=$3
             AND citation.input_snapshot_sha256=CAST($4 AS char(64))
             AND citation.proposal_payload_sha256=CAST($5 AS char(64))
             AND citation.supports_redacted=$6
             AND citation.agent_run_id=$7
             AND citation.provider_turn_id=$10
             AND ($9::uuid IS NULL OR citation.citation_id=$9)
             AND EXISTS (
               SELECT 1 FROM ops.agent_source_uses source_use
                WHERE source_use.agent_run_id=citation.agent_run_id
                  AND source_use.source_use_id=citation.source_use_id
                  AND source_use.source_use_sha256=citation.source_use_sha256
                  AND source_use.provider_turn_id=$10
                  AND source_use.use_kind='CITATION'
                  AND source_use.parent_source_use_sha256=CAST($8 AS char(64))
             )
        ) AS "exists!""#,
        proposal_id,
        validation_id,
        ordinal,
        &turn.input_snapshot_sha256,
        payload_sha256,
        supports,
        turn.run_id,
        source_use_sha256,
        citation_id,
        turn.turn_id,
    )
    .fetch_one(&mut *executor)
    .await
    .map_err(database)?;
    if !replayed {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "citation source use or replay binding not found".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CitationEligibility {
    internal_evidence: bool,
    official_unreviewed_artifact: bool,
}

fn citation_eligibility(proposal_type: &str) -> Result<CitationEligibility, Failure> {
    match proposal_type {
        "CLAIM" | "COMMUNICATION" => Ok(CitationEligibility {
            internal_evidence: false,
            official_unreviewed_artifact: false,
        }),
        "HYPOTHESIS" => Ok(CitationEligibility {
            internal_evidence: true,
            official_unreviewed_artifact: true,
        }),
        "TASK" | "COMPARABLE" => Ok(CitationEligibility {
            internal_evidence: true,
            official_unreviewed_artifact: false,
        }),
        _ => Err(Failure::Terminal(
            "AGENT_OUTPUT_INVALID",
            "citation proposal type".to_owned(),
        )),
    }
}

fn output_citation(output: &Value, citation_id: &str) -> Option<Value> {
    output
        .get("citations")?
        .as_array()?
        .iter()
        .find(|citation| citation.get("citationId").and_then(Value::as_str) == Some(citation_id))
        .cloned()
}

#[cfg(test)]
#[path = "citation_policy_tests.rs"]
mod policy_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::postgres::PgPoolOptions;

    const RUN_ID: &str = "8eee21b7-75c0-53c9-b079-d897a2c3c711";
    const TURN_ID: &str = "df45a69f-7ddb-5d39-b135-cc6eeacddd96";
    const INPUT_SNAPSHOT_ID: &str = "88c24d96-dcc6-5a62-bd26-61e5749d9bf6";
    const ARTIFACT_ID: &str = "facc134e-f4d3-551d-bb42-55d4495373ae";

    struct FixtureSource {
        source_use_sha256: String,
        locator: String,
        content_sha256: String,
    }

    fn fixture_uuid(value: &str) -> Uuid {
        Uuid::parse_str(value).expect("fixture UUID")
    }

    fn fixture_turn(prior_transcript_sha256: String) -> ProviderTurnIdentity {
        ProviderTurnIdentity {
            turn_id: fixture_uuid(TURN_ID),
            run_id: fixture_uuid(RUN_ID),
            idempotency_hash: "citation-integration-fixture".to_owned(),
            request_redacted: json!({}),
            dataset_snapshot_id: Some(fixture_uuid(INPUT_SNAPSHOT_ID)),
            input_snapshot_sha256: "9".repeat(64),
            prior_transcript_sha256,
            provider_config_id: Uuid::nil(),
            provider_mode: "LOCAL_APPROVED".to_owned(),
            provider_candidate_id: "control-fixture".to_owned(),
            model_id: "control-fixture-model".to_owned(),
            model_configuration_sha256: "1".repeat(64),
            routing_policy_version: "control-routing-v1".to_owned(),
            routing_decision_sha256: "2".repeat(64),
            prompt_id: "control-prompt".to_owned(),
            prompt_version: "v1".to_owned(),
            prompt_sha256: "3".repeat(64),
            output_schema_id: "source-fetch-response".to_owned(),
            output_schema_version: "v2".to_owned(),
            output_schema_sha256: "4".repeat(64),
            classification: "PUBLIC".to_owned(),
            model_use_rights_sha256: "5".repeat(64),
            budget_reservation_key_sha256: "6".repeat(64),
            dispatch_key_sha256: "7".repeat(64),
            request_sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
                .to_owned(),
            turn_sequence: 1,
            attempt_sequence: 1,
            dispatched_at: "2026-01-02T22:02:56Z".to_owned(),
        }
    }

    fn artifact_output(
        proposal_field: &str,
        proposal: Value,
        source_use_sha256: &str,
        locator: &str,
        content_sha256: &str,
    ) -> Value {
        let mut output = json!({
            "status":"COMPLETED",
            "summary":"공식 출처의 미검토 자료를 내부 가설로만 검토",
            "citations":[{
                "sourceUseSha256":source_use_sha256,
                "locator":{"kind":"HTML_CSS_SELECTOR","value":locator},
                "selectedContentSha256":content_sha256,
                "supports":"공식 출처에서 확보했으나 아직 사람이 승격하지 않은 자료",
                "supportsSha256":sha256("공식 출처에서 확보했으나 아직 사람이 승격하지 않은 자료".as_bytes())
            }]
        });
        output[proposal_field] = json!([proposal]);
        output
    }

    async fn fixture_source(pool: &sqlx::PgPool) -> (FixtureSource, String) {
        let row = sqlx::query!(
            r#"SELECT btrim(source_use.source_use_sha256::text) AS "source_use_sha256!",
                      source_use.locator_value AS "locator_value!",
                      btrim(source_use.selected_content_sha256::text) AS "content_sha256!",
                      btrim(tool.result_transcript_sha256::text) AS "result_transcript_sha256!"
                 FROM ops.agent_source_uses source_use
                 JOIN ops.agent_tool_calls tool
                   ON tool.agent_run_id=source_use.agent_run_id
                  AND tool.tool_call_id=source_use.tool_call_id
                WHERE source_use.agent_run_id=$1
                  AND source_use.use_kind='TOOL_QUERY'
                  AND source_use.source_kind='RESEARCH_ARTIFACT'
                  AND source_use.research_artifact_id=$2
                  AND tool.tool_id='source.fetch'
                  AND tool.status='SUCCEEDED'"#,
            fixture_uuid(RUN_ID),
            fixture_uuid(ARTIFACT_ID),
        )
        .fetch_one(pool)
        .await
        .expect("control research source.fetch fixture");
        (
            FixtureSource {
                source_use_sha256: row.source_use_sha256,
                locator: row.locator_value,
                content_sha256: row.content_sha256,
            },
            row.result_transcript_sha256,
        )
    }

    async fn persisted_counts(pool: &sqlx::PgPool) -> (i64, i64, i64, i64) {
        let row = sqlx::query!(
            r#"SELECT
                (SELECT count(*) FROM ops.agent_source_uses
                  WHERE agent_run_id=$1 AND provider_turn_id=$2 AND use_kind='CITATION') AS "source_uses!",
                (SELECT count(*) FROM ops.agent_output_validations
                  WHERE agent_run_id=$1 AND provider_turn_id=$2) AS "validations!",
                (SELECT count(*) FROM ops.agent_suggestions
                  WHERE agent_run_id=$1 AND citation_validation_id IN (
                    SELECT validation_id FROM ops.agent_output_validations
                     WHERE agent_run_id=$1 AND provider_turn_id=$2)) AS "suggestions!",
                (SELECT count(*) FROM ops.agent_proposal_citations
                  WHERE agent_run_id=$1 AND provider_turn_id=$2) AS "citations!""#,
            fixture_uuid(RUN_ID),
            fixture_uuid(TURN_ID),
        )
        .fetch_one(pool)
        .await
        .expect("citation side-effect counts");
        (
            row.source_uses,
            row.validations,
            row.suggestions,
            row.citations,
        )
    }

    async fn prove_hypothesis_artifact_citation(
        pool: &sqlx::PgPool,
        audit_pool: &sqlx::PgPool,
        turn: &ProviderTurnIdentity,
        source: &FixtureSource,
        before: (i64, i64, i64, i64),
    ) {
        let hypothesis = artifact_output(
            "hypotheses",
            json!({
                "proposalKind":"HYPOTHESIS",
                "proposalState":"PROPOSAL_ONLY",
                "statement":"공식 출처 자료가 추가 검증할 관계를 시사한다",
                "assessment":"UNRESOLVED",
                "supportingCitationIndexes":[0],
                "contradictingCitationIndexes":[],
                "unknowns":["독립 검증과 사람 승격 필요"]
            }),
            &source.source_use_sha256,
            &source.locator,
            &source.content_sha256,
        );
        let output_sha256 =
            sha256(&canonical_bytes(&hypothesis).expect("canonical hypothesis provider output"));
        let mut transaction = pool.begin().await.expect("positive transaction");
        super::super::super::insert_citation_source_uses(&mut transaction, turn, &hypothesis)
            .await
            .expect("production citation source-use transaction");
        super::super::super::insert_citation_source_uses(&mut transaction, turn, &hypothesis)
            .await
            .expect("citation source-use replay transaction");
        assert_eq!(citation_source_use_count(&mut transaction, turn).await, 1);
        super::super::insert_output_validation(
            &mut transaction,
            turn,
            &hypothesis,
            &output_sha256,
            &sha256(b"official-unreviewed-positive-receipt"),
        )
        .await
        .expect("production hypothesis citation transaction");
        assert_persisted_artifact_citation(&mut transaction, turn).await;
        transaction.rollback().await.expect("positive rollback");
        assert_eq!(persisted_counts(audit_pool).await, before);
    }

    async fn citation_source_use_count(
        transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        turn: &ProviderTurnIdentity,
    ) -> i64 {
        sqlx::query_scalar!(
            r#"SELECT count(*) AS "count!"
                 FROM ops.agent_source_uses
                WHERE agent_run_id=$1
                  AND provider_turn_id=$2
                  AND use_kind='CITATION'"#,
            turn.run_id,
            turn.turn_id,
        )
        .fetch_one(&mut **transaction)
        .await
        .expect("citation source-use replay count")
    }

    async fn assert_persisted_artifact_citation(
        transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        turn: &ProviderTurnIdentity,
    ) {
        let persisted = sqlx::query!(
            r#"SELECT citation.source_kind,
                      citation.provider_turn_id,
                      citation.research_artifact_id AS "research_artifact_id!",
                      source_use.source_kind AS "source_use_kind!",
                      source_use.provider_turn_id AS "source_use_provider_turn_id!",
                      convert_from(source_use.source_use_canonical,'UTF8')::jsonb AS "source_use_canonical!"
                 FROM ops.agent_proposal_citations citation
                 JOIN ops.agent_source_uses source_use
                   ON source_use.agent_run_id=citation.agent_run_id
                  AND source_use.source_use_id=citation.source_use_id
                  AND source_use.source_use_sha256=citation.source_use_sha256
                WHERE citation.agent_run_id=$1 AND citation.provider_turn_id=$2"#,
            turn.run_id,
            turn.turn_id,
        )
        .fetch_one(&mut **transaction)
        .await
        .expect("persisted artifact citation");
        assert_eq!(persisted.source_kind, "RUN_TOOL_ARTIFACT");
        assert_eq!(persisted.source_use_kind, "RESEARCH_ARTIFACT");
        assert_eq!(persisted.provider_turn_id, turn.turn_id);
        assert_eq!(persisted.source_use_provider_turn_id, turn.turn_id);
        assert_eq!(persisted.research_artifact_id, fixture_uuid(ARTIFACT_ID));
        assert_closed_citation_source_use(&persisted.source_use_canonical, turn.turn_id);
    }

    fn assert_closed_citation_source_use(canonical: &Value, turn_id: Uuid) {
        let object = canonical
            .as_object()
            .expect("closed source-use canonical object");
        assert_eq!(object.len(), 17);
        assert_eq!(object.get("schemaVersion"), Some(&json!("source-use.v2")));
        assert_eq!(object.get("useKind"), Some(&json!("CITATION")));
        assert_eq!(object.get("providerTurnId"), Some(&json!(turn_id)));
        assert_eq!(
            object
                .get("sourceIdentity")
                .and_then(|identity| identity.get("researchArtifactId")),
            Some(&json!(fixture_uuid(ARTIFACT_ID)))
        );
    }

    async fn prove_claim_artifact_rejection(
        pool: &sqlx::PgPool,
        audit_pool: &sqlx::PgPool,
        turn: &ProviderTurnIdentity,
        source: &FixtureSource,
        before: (i64, i64, i64, i64),
    ) {
        let claim = artifact_output(
            "claims",
            json!({"kind":"CLAIM","citationIndexes":[0]}),
            &source.source_use_sha256,
            &source.locator,
            &source.content_sha256,
        );
        let output_sha256 =
            sha256(&canonical_bytes(&claim).expect("canonical claim provider output"));
        let mut transaction = pool.begin().await.expect("negative transaction");
        super::super::super::insert_citation_source_uses(&mut transaction, turn, &claim)
            .await
            .expect("production citation source-use transaction");
        let failure = super::super::insert_output_validation(
            &mut transaction,
            turn,
            &claim,
            &output_sha256,
            &sha256(b"official-unreviewed-negative-receipt"),
        )
        .await
        .expect_err("CLAIM must reject an unreviewed research artifact");
        assert!(matches!(
            failure,
            Failure::Terminal("AGENT_OUTPUT_INVALID", _)
        ));
        transaction.rollback().await.expect("negative rollback");
        assert_eq!(persisted_counts(audit_pool).await, before);
    }

    #[tokio::test]
    #[ignore = "requires migrations plus control-runtime and control-research fixtures"]
    async fn official_unreviewed_artifact_is_persisted_only_for_hypotheses() {
        let database_url = std::env::var("ANALYSIS_DATABASE_URL")
            .expect("ANALYSIS_DATABASE_URL for the disposable fixture database");
        let pool = PgPoolOptions::new()
            .max_connections(2)
            .connect(&database_url)
            .await
            .expect("analysis fixture database");
        let audit_database_url =
            std::env::var("DATABASE_URL").expect("DATABASE_URL for fixture side-effect audit");
        let audit_pool = PgPoolOptions::new()
            .max_connections(1)
            .connect(&audit_database_url)
            .await
            .expect("fixture audit database");
        let (source, transcript_sha256) = fixture_source(&pool).await;
        let turn = fixture_turn(transcript_sha256);
        let before = persisted_counts(&audit_pool).await;
        prove_hypothesis_artifact_citation(&pool, &audit_pool, &turn, &source, before).await;
        prove_claim_artifact_rejection(&pool, &audit_pool, &turn, &source, before).await;
        audit_pool.close().await;
        pool.close().await;
    }
}
