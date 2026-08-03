use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Mutex, OnceLock},
};

use actix_web::HttpRequest;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use gurine_api_contracts::{
    OperationSpec,
    agent_snapshot::agent_case_snapshot_sha256,
    event::{producer_events, project_payload, requires_outbox},
};
use gurine_application::ports::DomainEventSink;
use gurine_auth::{
    assertion::{
        BoundRequest,
        actor::ActorClaims,
        canonical::{canonical_json, canonical_request_digest},
    },
    envelope::{EnvelopeKeyRing, encrypt},
};
use gurine_domain::{case::CASE_TRANSITIONS, state_catalog::InvestigationState};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, PgPool, Postgres, Transaction};
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

pub(super) struct OwnerCommandReceipt {
    pub aggregate_id: Uuid,
    pub aggregate_version: i64,
    pub audit_event_id: Uuid,
    pub receipt_digest: String,
    pub accepted_at: String,
    pub outbox_event_ids: Vec<Uuid>,
    pub expected_outbox_count: usize,
    pub response_fields: Map<String, Value>,
}

pub(super) struct CommandEffect {
    pub fields: Map<String, Value>,
    pub owner_receipt: Option<OwnerCommandReceipt>,
    pub owner_replaces_aggregate_id: bool,
}

impl CommandEffect {
    pub(super) fn none() -> Self {
        Self {
            fields: Map::new(),
            owner_receipt: None,
            owner_replaces_aggregate_id: false,
        }
    }

    pub(super) fn fields(fields: Map<String, Value>) -> Self {
        Self {
            fields,
            owner_receipt: None,
            owner_replaces_aggregate_id: false,
        }
    }

    pub(super) fn owner(receipt: OwnerCommandReceipt) -> Self {
        Self {
            fields: Map::new(),
            owner_receipt: Some(receipt),
            owner_replaces_aggregate_id: false,
        }
    }

    pub(super) fn owner_created(receipt: OwnerCommandReceipt) -> Self {
        Self {
            fields: Map::new(),
            owner_receipt: Some(receipt),
            owner_replaces_aggregate_id: true,
        }
    }
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
    #[error("an active legal hold blocks the requested control operation")]
    LegalHoldActive,
    #[error("the requested legal-hold target kind has no authoritative source relation")]
    LegalHoldTargetUnsupported,
    #[error("privacy identity proof does not bind the requested subject and scope")]
    IdentityProofInvalid,
    #[error("privacy request scope is invalid")]
    PrivacyScopeInvalid,
    #[error("the requested privacy-correction target has no authorized field mapping")]
    PrivacyCorrectionTargetUnsupported,
    #[error("privacy request decision version changed")]
    RetentionVersionConflict,
    #[error("privacy request state does not permit this operation")]
    RetentionStateInvalid,
    #[error("privacy response business calendar authority changed")]
    BusinessCalendarStale,
    #[error("required control dependency is unavailable")]
    DependencyUnavailable,
    #[error("control command capability is denied")]
    CapabilityDenied,
    #[error("control command requires a current step-up authorization")]
    StepUpRequired,
    #[error("provider control must be submitted through an action proposal")]
    ProposalRequired,
    #[error("idempotency key was reused with different request bytes")]
    IdempotencyConflict,
    #[error("control persistence is unavailable")]
    Persistence,
}

mod command;
mod domains;
mod economics_import;
mod owner_receipt;
mod publication;
mod publication_guard;
mod publication_guard_archive;
mod query_action_proposal;
mod query_analysis_vm;
mod query_business;
mod query_support;
mod registry;
mod response;
mod routing;
mod schema;
mod util;

use command::*;
pub(crate) use economics_import::authorization::{
    caller_selects_economics_import, economics_import_kind_may_be_persisted,
    required as economics_import_authorization_required,
};
use economics_import::*;
use owner_receipt::*;
use publication::*;
use publication_guard::*;
use publication_guard_archive::*;
use query_action_proposal::*;
use query_analysis_vm::*;
use query_business::*;
use query_support::*;
use response::*;
use routing::*;
use schema::*;
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
    reject_direct_provider_control(operation.id)?;
    let handler = registry::lookup(operation.id)?;
    if operation.operation_kind == "QUERY" {
        let registry::Handler::Query(handler) = handler else {
            return Err(ServiceError::InvalidRequest);
        };
        return registered_query(handler, operation, request, claims, pool).await;
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
    let registry::Handler::Command(handler) = handler else {
        return Err(ServiceError::InvalidRequest);
    };
    command(
        handler,
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

pub(crate) fn reject_direct_provider_control(operation_id: &str) -> Result<(), ServiceError> {
    if matches!(
        operation_id,
        "disableProviderRouting"
            | "testProviderConnection"
            | "upgradeProviderModel"
            | "setModelAutoUpgrade"
    ) {
        Err(ServiceError::ProposalRequired)
    } else {
        Ok(())
    }
}

async fn registered_query(
    handler: registry::QueryHandler,
    operation: &OperationSpec,
    request: &HttpRequest,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Output, ServiceError> {
    let parameters = query_parameters(operation.id, request)?;
    let mut data = domains::query(handler, operation, &parameters, claims, pool).await?;
    if operation.id != "exportCostReport"
        && let Some(object) = data.as_object_mut()
    {
        object.entry("operationId").or_insert(json!(operation.id));
    }
    let data = if operation.id == "getActionProposal" {
        action_proposal_detail_response(data)
    } else {
        data
    };
    let response = response_for(operation, &data)?;
    Ok(Output {
        status: operation.success_status,
        media_type: "application/json",
        body: response,
        replay: false,
    })
}

fn envelope(id: Uuid, status: impl Into<String>, data: Value) -> Value {
    let status = status.into();
    json!({"id":id,"status":status,"data":data,"links":[]})
}

fn value_status(value: &Value) -> String {
    value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("READY")
        .to_owned()
}

fn query_uuid(parameters: &BTreeMap<String, String>, name: &str) -> Result<Uuid, ServiceError> {
    parameters
        .get(name)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)
}

#[cfg(test)]
mod tests {
    use actix_web::test::TestRequest;

    use super::*;

    #[test]
    fn provider_control_direct_operations_require_action_proposals() {
        for operation_id in [
            "disableProviderRouting",
            "testProviderConnection",
            "upgradeProviderModel",
            "setModelAutoUpgrade",
        ] {
            assert!(matches!(
                reject_direct_provider_control(operation_id),
                Err(ServiceError::ProposalRequired)
            ));
        }
    }

    #[test]
    fn non_provider_control_operations_keep_the_existing_dispatch_path() {
        for operation_id in ["cancelJob", "listProviders", "createActionProposal"] {
            assert!(reject_direct_provider_control(operation_id).is_ok());
        }
    }

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
        let parameters = query_parameters("getInternalCase", &request)
            .unwrap_or_else(|error| panic!("query parameters must parse: {error}"));
        assert_eq!(
            parameters.get("caseId").map(String::as_str),
            Some("path-case")
        );
        assert_eq!(parameters.get("locale").map(String::as_str), Some("ko"));
    }

    #[test]
    fn repeated_array_query_parameters_preserve_wire_order_and_decoding() {
        let request = TestRequest::with_uri(
            "/v1/internal/queries/list-retention-requests?requestType=ACCESS%2CDELETION&requestType=CORRECTION&state=RECEIVED&state=REVIEW",
        )
        .to_http_request();
        let parameters = query_parameters("listRetentionRequests", &request)
            .unwrap_or_else(|error| panic!("array query parameters must parse: {error}"));
        assert_eq!(
            parameters.get("requestType").map(String::as_str),
            Some("ACCESS,DELETION,CORRECTION")
        );
        assert_eq!(
            parameters.get("state").map(String::as_str),
            Some("RECEIVED,REVIEW")
        );

        let non_privacy_request = TestRequest::with_uri(
            "/v1/internal/queries/list-jobs?jobStatus=QUEUED&jobStatus=RUNNING",
        )
        .to_http_request();
        let non_privacy_parameters = query_parameters("listJobs", &non_privacy_request)
            .unwrap_or_else(|error| panic!("OpenAPI array metadata must be generic: {error}"));
        assert_eq!(
            non_privacy_parameters.get("jobStatus").map(String::as_str),
            Some("QUEUED,RUNNING")
        );
    }

    #[test]
    fn undeclared_repeated_query_parameters_fail_closed() {
        let request =
            TestRequest::with_uri("/v1/internal/queries/list-jobs?status=QUEUED&status=RUNNING")
                .to_http_request();
        assert!(matches!(
            query_parameters("listJobs", &request),
            Err(ServiceError::InvalidRequest)
        ));
    }

    #[test]
    fn duplicate_scalar_query_parameters_fail_closed() {
        let request =
            TestRequest::with_uri("/v1/internal/queries/list-retention-requests?limit=20&limit=50")
                .to_http_request();
        assert!(matches!(
            query_parameters("listRetentionRequests", &request),
            Err(ServiceError::InvalidRequest)
        ));
    }

    #[test]
    fn empty_array_elements_are_preserved_for_the_domain_validator() {
        let request = TestRequest::with_uri(
            "/v1/internal/queries/list-retention-requests?requestType=&requestType=ACCESS",
        )
        .to_http_request();
        let parameters = query_parameters("listRetentionRequests", &request)
            .unwrap_or_else(|error| panic!("wire query must remain lossless: {error}"));
        assert_eq!(
            parameters.get("requestType").map(String::as_str),
            Some(",ACCESS")
        );
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
