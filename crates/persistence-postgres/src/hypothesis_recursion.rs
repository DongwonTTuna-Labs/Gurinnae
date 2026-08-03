#![forbid(unsafe_code)]

use gurine_domain::{
    error::DomainError,
    hypothesis_recursion::{
        HypothesisRecursion, HypothesisRecursionDisposition, HypothesisRecursionProducerFence,
        HypothesisRecursionStarted, HypothesisRecursionTriggerKind,
    },
};
use serde_json::{Map, Value};
use sqlx::PgPool;
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum HypothesisRecursionRepositoryError {
    #[error("hypothesis recursion database operation failed")]
    Database(#[from] sqlx::Error),
    #[error("hypothesis recursion owner result violated the domain contract")]
    Contract(#[from] DomainError),
}

/// The only application write boundary for the six immutable recursion
/// relations. Both methods delegate to migration-owned, lease-fenced routines;
/// this repository intentionally exposes no direct table mutation.
#[derive(Clone)]
pub struct HypothesisRecursionRepository {
    pool: PgPool,
}

impl HypothesisRecursionRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn process_hypothesis_execution_completed(
        &self,
        payload: &Map<String, Value>,
        producer_fence: &HypothesisRecursionProducerFence,
    ) -> Result<HypothesisRecursion, HypothesisRecursionRepositoryError> {
        let event_payload = Value::Object(payload.clone());
        let outcome = sqlx::query_as!(
            OwnerOutcomeRow,
            r#"SELECT
                 disposition AS "disposition!", receipt_id AS "receipt_id!",
                 plan_id, node_id, agent_run_id, job_id,
                 receipt_digest::text AS "receipt_digest!", replayed AS "replayed!"
               FROM ops.process_hypothesis_execution_completed_v1($1,$2,$3,$4)"#,
            event_payload,
            producer_fence.job_id().value(),
            producer_fence.lease_token(),
            producer_fence.fencing_token(),
        )
        .fetch_one(&self.pool)
        .await?;
        outcome.into_domain(HypothesisRecursionTriggerKind::ActionExecution)
    }

    pub async fn process_recursion_stage_completed(
        &self,
        payload: &Map<String, Value>,
        producer_fence: &HypothesisRecursionProducerFence,
    ) -> Result<HypothesisRecursion, HypothesisRecursionRepositoryError> {
        let event_payload = Value::Object(payload.clone());
        let outcome = sqlx::query_as!(
            OwnerOutcomeRow,
            r#"SELECT
                 disposition AS "disposition!", receipt_id AS "receipt_id!",
                 plan_id, node_id, agent_run_id, job_id,
                 receipt_digest::text AS "receipt_digest!", replayed AS "replayed!"
               FROM ops.process_hypothesis_recursion_stage_completed_v1($1,$2,$3,$4)"#,
            event_payload,
            producer_fence.job_id().value(),
            producer_fence.lease_token(),
            producer_fence.fencing_token(),
        )
        .fetch_one(&self.pool)
        .await?;
        outcome.into_domain(HypothesisRecursionTriggerKind::AgentRun)
    }
}

#[derive(Debug)]
struct OwnerOutcomeRow {
    disposition: String,
    receipt_id: Uuid,
    plan_id: Option<Uuid>,
    node_id: Option<Uuid>,
    agent_run_id: Option<Uuid>,
    job_id: Option<Uuid>,
    receipt_digest: String,
    replayed: bool,
}

impl OwnerOutcomeRow {
    fn into_domain(
        self,
        trigger_kind: HypothesisRecursionTriggerKind,
    ) -> Result<HypothesisRecursion, HypothesisRecursionRepositoryError> {
        let disposition = HypothesisRecursionDisposition::try_from(self.disposition.as_str())?;
        let started = match (self.plan_id, self.node_id, self.agent_run_id, self.job_id) {
            (Some(plan_id), Some(node_id), Some(agent_run_id), Some(job_id)) => Some(
                HypothesisRecursionStarted::try_new(plan_id, node_id, agent_run_id, job_id)?,
            ),
            (None, None, None, None) => None,
            _ => return Err(DomainError::InvalidTransition.into()),
        };
        HypothesisRecursion::from_owner_result(
            trigger_kind,
            disposition,
            self.receipt_id,
            self.receipt_digest.trim(),
            started,
            self.replayed,
        )
        .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn row(disposition: &str) -> OwnerOutcomeRow {
        OwnerOutcomeRow {
            disposition: disposition.to_owned(),
            receipt_id: Uuid::from_u128(1),
            plan_id: None,
            node_id: None,
            agent_run_id: None,
            job_id: None,
            receipt_digest: DIGEST.to_owned(),
            replayed: false,
        }
    }

    #[test]
    fn maps_exact_started_and_no_start_shapes() {
        assert!(
            row("POLICY_DISABLED")
                .into_domain(HypothesisRecursionTriggerKind::ActionExecution)
                .is_ok()
        );

        let mut started = row("STARTED");
        started.plan_id = Some(Uuid::from_u128(2));
        started.node_id = Some(Uuid::from_u128(3));
        started.agent_run_id = Some(Uuid::from_u128(4));
        started.job_id = Some(Uuid::from_u128(5));
        let aggregate = started
            .into_domain(HypothesisRecursionTriggerKind::AgentRun)
            .expect("valid started owner result");
        assert_eq!(
            aggregate.disposition(),
            HypothesisRecursionDisposition::Started
        );
        assert!(aggregate.started().is_some());
    }

    #[test]
    fn rejects_partial_identities_unknown_disposition_and_bad_digest() {
        let mut partial = row("STARTED");
        partial.plan_id = Some(Uuid::from_u128(2));
        assert!(
            partial
                .into_domain(HypothesisRecursionTriggerKind::AgentRun)
                .is_err()
        );
        assert!(
            row("CLAIM_DRAFTER_STARTED")
                .into_domain(HypothesisRecursionTriggerKind::AgentRun)
                .is_err()
        );
        let mut bad_digest = row("POLICY_ABSENT");
        bad_digest.receipt_digest = "A".repeat(64);
        assert!(
            bad_digest
                .into_domain(HypothesisRecursionTriggerKind::ActionExecution)
                .is_err()
        );
    }
}
