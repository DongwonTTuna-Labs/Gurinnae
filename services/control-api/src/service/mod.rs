use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Mutex, OnceLock},
};

use actix_web::HttpRequest;
use gurine_api_contracts::{
    OperationSpec,
    agent_snapshot::agent_case_snapshot_sha256,
    event::{producer_events, project_payload, requires_outbox},
};
use gurine_application::ports::DomainEventSink;
use gurine_auth::{
    assertion::{BoundRequest, actor::ActorClaims, canonical::canonical_request_digest},
    envelope::{EnvelopeKeyRing, encrypt},
};
use gurine_domain::{case::CASE_TRANSITIONS, state_catalog::InvestigationState};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, PgPool, Postgres, Row, Transaction};
use thiserror::Error;
use time::{Date, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::state::InProcessDomainEventJournal;

const CONTROL_OPENAPI: &str = include_str!("../../../../specs/generated/control-api.openapi.json");
static SPEC: OnceLock<Result<Value, ()>> = OnceLock::new();
static CONCURRENCY: OnceLock<Result<ConcurrencyCatalog, ()>> = OnceLock::new();
const CONCURRENCY_JSON: &str =
    include_str!("../../../../specs/application/optimistic-concurrency.runtime.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConcurrencyCatalog {
    contracts: Vec<ConcurrencyContract>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConcurrencyContract {
    operation_id: String,
    version_field: String,
    guard_relation: String,
    guard_columns: Vec<String>,
    request_placeholders: Vec<String>,
}

pub struct Output {
    pub status: u16,
    pub media_type: &'static str,
    pub body: Value,
    pub replay: bool,
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("control request is invalid")]
    InvalidRequest,
    #[error("control resource was not found")]
    NotFound,
    #[error("control resource version conflicts")]
    VersionConflict,
    #[error("control resource state transition is invalid")]
    InvalidStateTransition,
    #[error("control command precondition failed")]
    PreconditionFailed,
    #[error("control command capability is denied")]
    CapabilityDenied,
    #[error("idempotency key was reused with different request bytes")]
    IdempotencyConflict,
    #[error("control persistence is unavailable")]
    Persistence,
}

mod command;
mod publication;
mod query_analysis_vm;
mod query_business;
mod query_dispatch;
mod query_support;
mod response;
mod routing;
mod schema;
mod specialized;
mod specialized_group_1;
mod specialized_group_2;
mod specialized_group_3;
mod specialized_group_4;
mod specialized_group_5;
mod specialized_group_5_signal;
mod specialized_group_6;
mod specialized_group_7;
mod util;

use command::*;
use publication::*;
use query_analysis_vm::*;
use query_business::*;
use query_dispatch::*;
use query_support::*;
use response::*;
use routing::*;
use schema::*;
use specialized::*;
use specialized_group_1::*;
use specialized_group_2::*;
use specialized_group_3::*;
use specialized_group_4::*;
use specialized_group_5::*;
use specialized_group_5_signal::*;
use specialized_group_6::*;
use specialized_group_7::*;
use util::*;

pub async fn execute(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    claims: &ActorClaims,
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    domain_events: &Mutex<InProcessDomainEventJournal>,
    request_id: Uuid,
) -> Result<Output, ServiceError> {
    if operation.operation_kind == "QUERY" {
        return query(operation, request, claims, pool).await;
    }
    if operation.api != "control-api"
        || operation.operation_kind != "COMMAND"
        || !gurine_api_contracts::control_api::OPERATIONS
            .iter()
            .chain(gurine_api_contracts::addendum::CONTROL_OPERATIONS.iter())
            .any(|candidate| candidate.id == operation.id && candidate.operation_kind == "COMMAND")
    {
        return Err(ServiceError::InvalidRequest);
    }
    command(
        operation,
        request,
        body,
        claims,
        pool,
        field_keys,
        domain_events,
        request_id,
    )
    .await
}

#[cfg(test)]
mod tests {
    use actix_web::test::TestRequest;

    use super::*;

    #[test]
    fn unknown_command_is_rejected_before_persistence() {
        let payload = Map::new();
        assert!(matches!(
            validate_command("unknownCommand", &payload),
            Err(ServiceError::InvalidRequest)
        ));
    }

    #[test]
    fn path_parameters_override_spoofed_query_values() {
        let request =
            TestRequest::with_uri("/v1/internal/cases/path-case?caseId=query-case&locale=ko")
                .param("caseId", "path-case")
                .to_http_request();
        let parameters = query_parameters(&request);
        assert_eq!(
            parameters.get("caseId").map(String::as_str),
            Some("path-case")
        );
        assert_eq!(parameters.get("locale").map(String::as_str), Some("ko"));
    }

    #[test]
    fn path_parameters_override_spoofed_command_values() {
        let request = TestRequest::with_uri("/v1/internal/saved-views/path-view")
            .param("savedViewId", "path-view")
            .to_http_request();
        let payload = json!({
            "savedViewId": "body-view",
            "expectedVersion": 1
        });
        let parameters = command_parameters(
            &request,
            payload
                .as_object()
                .expect("command payload must be an object"),
        );
        assert_eq!(
            parameters.get("savedViewId").and_then(Value::as_str),
            Some("path-view")
        );
        assert_eq!(parameters.get("expectedVersion"), Some(&json!(1)));
    }

    #[test]
    fn schema_mapping_digest_binds_key_sorted_compact_json() -> Result<(), ServiceError> {
        let mappings = json!([{
            "upstreamPath": "supplier.name",
            "canonicalField": "supplierName",
            "transform": "trim",
            "required": true
        }]);
        let expected = sha256(
            br#"[{"canonicalField":"supplierName","required":true,"transform":"trim","upstreamPath":"supplier.name"}]"#,
        );
        assert!(mapping_digest_matches(&mappings, &expected)?);
        assert!(!mapping_digest_matches(&mappings, &"0".repeat(64))?);
        Ok(())
    }

    #[test]
    fn case_transition_pairs_match_the_final_state_machine() {
        assert!(valid_case_transition("CLOSED", "INVESTIGATING"));
        assert!(valid_case_transition("LEGAL_REVIEW", "INVESTIGATING"));
        assert!(valid_case_transition("READY_TO_PUBLISH", "INVESTIGATING"));
        assert!(valid_case_transition("LEGAL_REVIEW", "CLOSED"));
        assert!(!valid_case_transition("LEGAL_REVIEW", "EDITORIAL_REVIEW"));
        assert!(!valid_case_transition(
            "READY_TO_PUBLISH",
            "EDITORIAL_REVIEW"
        ));
        assert!(!valid_case_transition("CLOSED", "READY_TO_PUBLISH"));
    }

    #[test]
    fn invalid_state_transition_is_distinct_from_version_conflict() {
        assert!(matches!(
            ServiceError::InvalidStateTransition,
            ServiceError::InvalidStateTransition
        ));
        assert_eq!(
            ServiceError::InvalidStateTransition.to_string(),
            "control resource state transition is invalid"
        );
    }
}
