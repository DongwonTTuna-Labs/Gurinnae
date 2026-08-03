#![forbid(unsafe_code)]

//! PostgreSQL boundary for the typed relationship graph.
//!
//! Every mutation and snapshot read is delegated to a 0037 owner routine. The
//! repository never performs direct DML against immutable graph tables.

mod decode;
mod wire;

use decode::*;
use gurine_domain::relationship_graph::*;
use serde_json::Value;
use sqlx::PgConnection;
use time::{Date, OffsetDateTime};
use uuid::Uuid;
use wire::*;

#[derive(Clone, Copy, Debug, Default)]
pub struct RelationshipGraphRepository;

impl RelationshipGraphRepository {
    pub async fn record_endpoint(
        connection: &mut PgConnection,
        command: &RecordRelationshipGraphEndpointV2,
    ) -> Result<RelationshipGraphEndpointV2, sqlx::Error> {
        command.validate().map_err(domain_decode)?;
        let request = endpoint_request(command);
        let response = sqlx::query_scalar!(
            "SELECT core.record_typed_relationship_endpoint_v2($1::jsonb)",
            sqlx::types::Json(&request) as _,
        )
        .fetch_one(&mut *connection)
        .await?
        .ok_or_else(unexpected_null)?;
        let endpoint = decode_endpoint_response(response)?;
        if endpoint.endpoint_kind != command.kind {
            return Err(domain_decode(RelationshipGraphError::InvalidState));
        }
        Ok(endpoint)
    }

    pub async fn record_assertion(
        connection: &mut PgConnection,
        command: &RecordRelationshipGraphAssertionV2,
    ) -> Result<RelationshipGraphAssertionV2, sqlx::Error> {
        command.validate().map_err(domain_decode)?;
        let request = assertion_request(command);
        let row = sqlx::query_as!(
            AssertionRow,
            r#"
            SELECT
              assertion_id AS "assertion_id!: Uuid",
              assertion_revision AS "assertion_revision!: i64",
              btrim(assertion_digest::text) AS "assertion_digest!: String",
              btrim(receipt_sha256::text) AS "receipt_sha256!: String",
              verification_status AS "verification_status!: String",
              public_use_status AS "public_use_status!: String",
              disposition AS "disposition!: String",
              replayed AS "replayed!: bool"
            FROM core.record_typed_relationship_assertion_v2($1::jsonb)
            "#,
            sqlx::types::Json(&request) as _,
        )
        .fetch_one(&mut *connection)
        .await?;
        if row.disposition != "PENDING_HUMAN"
            || row.assertion_id != command.assertion_id.value()
            || row.assertion_revision != 1
            || row.verification_status != "PENDING_HUMAN"
            || row.public_use_status != "NOT_REVIEWED"
        {
            return Err(domain_decode(RelationshipGraphError::InvalidState));
        }
        assertion_from_row(row)
    }

    pub async fn decide_assertion(
        connection: &mut PgConnection,
        command: &DecideRelationshipGraphAssertionV2,
    ) -> Result<RelationshipGraphVerificationDecisionV2, sqlx::Error> {
        command.validate().map_err(domain_decode)?;
        let request = decision_request(command);
        let row = sqlx::query_as!(
            DecisionRow,
            r#"
            SELECT
              decision_id AS "decision_id!: Uuid",
              assertion_id AS "assertion_id!: Uuid",
              assertion_revision AS "assertion_revision!: i64",
              btrim(assertion_digest::text) AS "assertion_digest!: String",
              verification_status AS "verification_status!: String",
              public_use_status AS "public_use_status!: String",
              btrim(receipt_sha256::text) AS "receipt_sha256!: String",
              replayed AS "replayed!: bool"
            FROM core.decide_typed_relationship_assertion_v2($1,$2::jsonb)
            "#,
            command.assertion_id.value(),
            sqlx::types::Json(&request) as _,
        )
        .fetch_one(&mut *connection)
        .await?;
        let (expected_status, expected_public_use) = expected_decision(command.decision);
        if row.assertion_id != command.assertion_id.value()
            || row.verification_status != expected_status
            || row.public_use_status != expected_public_use
        {
            return Err(domain_decode(RelationshipGraphError::InvalidState));
        }
        decision_from_row(row)
    }

    pub async fn list_neighbors(
        connection: &mut PgConnection,
        command: &ListRelationshipNeighborsV3,
    ) -> Result<RelationshipNeighborsV3, sqlx::Error> {
        command.validate().map_err(domain_decode)?;
        let generation = i64::try_from(command.snapshot_generation)
            .map_err(|_| domain_decode(RelationshipGraphError::InvalidQuery))?;
        let rebuilt = canonical_json(&neighbors_request(command)).map_err(json_decode)?;
        if rebuilt != command.request_canonical {
            return Err(domain_decode(RelationshipGraphError::InvalidQuery));
        }
        let canonical = &command.request_canonical;
        let expected_digest = Sha256Digest::new(hex_digest(&canonical)).map_err(domain_decode)?;
        let rows = Self::query_neighbors(connection, command, generation, canonical).await?;
        let neighbors = rows
            .into_iter()
            .map(|row| neighbor_from_row(row, &expected_digest))
            .collect::<Result<Vec<_>, _>>()?;
        if neighbors.len() > usize::from(command.limit)
            || neighbors
                .iter()
                .any(|neighbor| !neighbor_matches(command, neighbor))
        {
            return Err(domain_decode(RelationshipGraphError::InvalidQuery));
        }
        Ok(RelationshipNeighborsV3 {
            query_digest: expected_digest,
            neighbors,
        })
    }

    async fn query_neighbors(
        connection: &mut PgConnection,
        command: &ListRelationshipNeighborsV3,
        generation: i64,
        canonical: &[u8],
    ) -> Result<Vec<NeighborRow>, sqlx::Error> {
        sqlx::query_as!(
            NeighborRow,
            r#"
            SELECT
              btrim(query_digest::text) AS "query_digest!: String",
              relationship_kind AS "relationship_kind!: String",
              subject AS "subject!: Value",
              object AS "object!: Value",
              assertion_id AS "assertion_id!: Uuid",
              assertion_revision AS "assertion_revision!: i64",
              btrim(assertion_digest::text) AS "assertion_digest!: String",
              valid_from AS "valid_from?: Date",
              valid_to AS "valid_to?: Date",
              evidence_count AS "evidence_count!: i32",
              btrim(evidence_set_digest::text) AS "evidence_set_digest!: String",
              subject_source_use_id AS "subject_source_use_id!: Uuid",
              btrim(subject_source_use_sha256::text)
                AS "subject_source_use_sha256!: String",
              object_source_use_id AS "object_source_use_id!: Uuid",
              btrim(object_source_use_sha256::text)
                AS "object_source_use_sha256!: String",
              verification_status AS "verification_status!: String",
              public_use_status AS "public_use_status!: String",
              proposed_actor_type AS "proposed_actor_type!: String",
              proposed_actor_id AS "proposed_actor_id!: String",
              verified_by AS "verified_by!: Uuid",
              verified_at AS "verified_at!: OffsetDateTime",
              btrim(verification_reason_digest::text)
                AS "verification_reason_digest!: String"
            FROM core.list_typed_relationship_neighbors_v3(
              $1,$2,$3,CAST($4 AS char(64)),$5,$6
            )
            "#,
            command.agent_run_id.value(),
            command.snapshot_id.value(),
            generation,
            command.snapshot_sha256.as_str(),
            canonical,
            i64::from(command.limit),
        )
        .fetch_all(&mut *connection)
        .await
    }
}

fn expected_decision(decision: RelationshipDecisionKindV2) -> (&'static str, &'static str) {
    match decision {
        RelationshipDecisionKindV2::Verify => ("VERIFIED", "APPROVED"),
        RelationshipDecisionKindV2::Reject => ("REJECTED", "DENIED"),
        RelationshipDecisionKindV2::MarkConflict => ("CONFLICTED", "DENIED"),
        RelationshipDecisionKindV2::Supersede => ("SUPERSEDED", "DENIED"),
    }
}

fn neighbor_matches(
    command: &ListRelationshipNeighborsV3,
    neighbor: &RelationshipNeighborV3,
) -> bool {
    let selector_matches =
        neighbor.subject == command.selector || neighbor.object == command.selector;
    let kind_matches = command.relationship_kinds.is_empty()
        || command
            .relationship_kinds
            .contains(&neighbor.relationship_kind);
    let date_matches = command.as_of.is_none_or(|as_of| {
        neighbor.valid_from.is_none_or(|from| from <= as_of)
            && neighbor.valid_to.is_none_or(|to| to >= as_of)
    });
    selector_matches && kind_matches && date_matches
}

#[derive(Debug)]
pub(super) struct AssertionRow {
    assertion_id: Uuid,
    assertion_revision: i64,
    assertion_digest: String,
    receipt_sha256: String,
    verification_status: String,
    public_use_status: String,
    disposition: String,
    replayed: bool,
}

#[derive(Debug)]
pub(super) struct DecisionRow {
    decision_id: Uuid,
    assertion_id: Uuid,
    assertion_revision: i64,
    assertion_digest: String,
    verification_status: String,
    public_use_status: String,
    receipt_sha256: String,
    replayed: bool,
}

#[derive(Debug)]
pub(super) struct NeighborRow {
    query_digest: String,
    relationship_kind: String,
    subject: Value,
    object: Value,
    assertion_id: Uuid,
    assertion_revision: i64,
    assertion_digest: String,
    valid_from: Option<Date>,
    valid_to: Option<Date>,
    evidence_count: i32,
    evidence_set_digest: String,
    subject_source_use_id: Uuid,
    subject_source_use_sha256: String,
    object_source_use_id: Uuid,
    object_source_use_sha256: String,
    verification_status: String,
    public_use_status: String,
    proposed_actor_type: String,
    proposed_actor_id: String,
    verified_by: Uuid,
    verified_at: OffsetDateTime,
    verification_reason_digest: String,
}
