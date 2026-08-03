use std::sync::Mutex;

use actix_web::{App, test as actix_test};
use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::{EnvelopeKey, EnvelopeKeyRing},
};
use sqlx::postgres::PgPoolOptions;

use super::*;
use crate::state::InProcessDomainEventJournal;

const CONDITIONAL_OPERATION: OperationSpec = OperationSpec {
    id: "submitActionDecision",
    api: "control-api",
    method: "POST",
    path: "/v1/internal/action-proposals/{proposalId}:decide",
    auth: "actor-assertion",
    capability: "actions.review",
    idempotency_required: true,
    assurance_level: "conditional-by-action-and-decision",
    step_up_required: false,
    operation_kind: "COMMAND",
    success_status: 200,
    media_type: "application/json",
    response_json: "{}",
};

const NEXT_SESSION: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn unsigned_next_submission_session_reaches_actor_rejection() {
    let request = actix_test::TestRequest::post()
        .uri("/v1/internal/commands/publish-case")
        .insert_header(("x-gurine-next-submission-session", NEXT_SESSION))
        .to_http_request();
    assert_eq!(
        next_submission_session_header(&request),
        Ok(Some(NEXT_SESSION))
    );
}

#[test]
fn duplicate_next_submission_session_is_rejected() {
    let request = actix_test::TestRequest::post()
        .uri("/v1/internal/commands/publish-case")
        .append_header(("x-gurine-next-submission-session", NEXT_SESSION))
        .append_header((
            "x-gurine-next-submission-session",
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        ))
        .to_http_request();
    assert_eq!(
        next_submission_session_header(&request),
        Err(AssertionError::RequestMismatch)
    );
}

#[test]
fn proposal_required_error_uses_the_closed_problem_contract() {
    assert_eq!(
        service_error_contract(&service::ServiceError::ProposalRequired),
        ("ACTION_PROPOSAL_REQUIRED", 409)
    );
}

#[test]
fn privacy_dependency_error_does_not_reclassify_generic_persistence_failures() {
    assert_eq!(
        service_error_contract(&service::ServiceError::DependencyUnavailable),
        ("DEPENDENCY_UNAVAILABLE", 503)
    );
    assert_eq!(
        service_error_contract(&service::ServiceError::Persistence),
        ("INTERNAL_ERROR", 500)
    );
}

#[actix_web::test]
async fn registered_provider_control_routes_return_conflict_without_a_database()
-> Result<(), sqlx::Error> {
    let state = web::Data::new(AppState {
        pool: PgPoolOptions::new().connect_lazy("postgresql://gurine:unused@127.0.0.1:1/gurine")?,
        assertion_keys: KeyRing {
            current: AssertionKey::new([1_u8; 32]),
            previous: None,
        },
        field_keys: EnvelopeKeyRing {
            current: EnvelopeKey::new([2_u8; 32]),
            previous: None,
        },
        domain_events: Mutex::new(InProcessDomainEventJournal::default()),
    });
    let app = actix_test::init_service(App::new().app_data(state).configure(configure)).await;

    for operation_id in [
        "disableProviderRouting",
        "testProviderConnection",
        "upgradeProviderModel",
        "setModelAutoUpgrade",
    ] {
        let operation = OPERATIONS
            .iter()
            .find(|operation| operation.id == operation_id)
            .ok_or(sqlx::Error::RowNotFound)?;
        let request = actix_test::TestRequest::post()
            .uri(operation.path)
            .set_payload("{}")
            .to_request();
        let response = actix_test::call_service(&app, request).await;
        assert_eq!(
            response.status(),
            StatusCode::CONFLICT,
            "direct route was not fenced for {operation_id}"
        );
        let body: Value = actix_test::read_body_json(response).await;
        assert_eq!(
            body.get("code").and_then(Value::as_str),
            Some("ACTION_PROPOSAL_REQUIRED")
        );
    }
    Ok(())
}

#[test]
fn provider_control_approval_selects_the_closed_operation_assurance() {
    for (provider_operation_id, expected) in [
        ("testProviderConnection", "ACTIVE_SESSION"),
        ("disableProviderRouting", "STEP_UP"),
        ("upgradeProviderModel", "STEP_UP"),
        ("setModelAutoUpgrade", "STEP_UP"),
    ] {
        let body = format!(
            r#"{{"actionKind":"PROVIDER_CONTROL","providerOperationId":"{provider_operation_id}","decision":{{"kind":"APPROVE"}}}}"#
        );
        assert_eq!(
            effective_authorization(&CONDITIONAL_OPERATION, body.as_bytes(), false).assurance,
            expected,
            "wrong assurance for {provider_operation_id}"
        );
    }
}

#[test]
fn provider_control_approval_fails_closed_for_missing_or_unknown_operation() {
    for body in [
        br#"{"actionKind":"PROVIDER_CONTROL","decision":{"kind":"APPROVE"}}"#.as_slice(),
        br#"{"actionKind":"PROVIDER_CONTROL","providerOperationId":"futureProviderCommand","decision":{"kind":"APPROVE"}}"#.as_slice(),
    ] {
        assert_eq!(
            effective_authorization(&CONDITIONAL_OPERATION, body, false).assurance,
            "STEP_UP"
        );
    }
}

#[test]
fn provider_control_non_approval_decisions_remain_active_session() {
    for decision in ["REJECT", "CHANGES_REQUIRED", "RECUSE"] {
        let body = format!(
            r#"{{"actionKind":"PROVIDER_CONTROL","providerOperationId":"upgradeProviderModel","decision":{{"kind":"{decision}"}}}}"#
        );
        assert_eq!(
            effective_authorization(&CONDITIONAL_OPERATION, body.as_bytes(), false).assurance,
            "ACTIVE_SESSION",
            "wrong assurance for {decision}"
        );
    }
}

#[test]
fn economics_import_approval_requires_step_up() {
    let body = br#"{"actionKind":"ECONOMICS_IMPORT","decision":{"kind":"APPROVE"}}"#;
    assert_eq!(
        effective_authorization(&CONDITIONAL_OPERATION, body, true).assurance,
        "STEP_UP"
    );
}

#[test]
fn economics_import_non_approval_decisions_also_require_step_up() {
    for decision in ["REJECT", "CHANGES_REQUIRED", "RECUSE"] {
        let body =
            format!(r#"{{"actionKind":"ECONOMICS_IMPORT","decision":{{"kind":"{decision}"}}}}"#);
        assert_eq!(
            effective_authorization(&CONDITIONAL_OPERATION, body.as_bytes(), true).assurance,
            "STEP_UP",
            "wrong assurance for {decision}"
        );
    }
}

#[test]
fn funding_disclosure_keeps_the_existing_http_authorization_delta_zero() {
    let body = br#"{"actionKind":"FUNDING_DISCLOSURE","decision":{"kind":"APPROVE"}}"#;
    assert_eq!(
        effective_authorization(&CONDITIONAL_OPERATION, body, false),
        EffectiveAuthorization {
            capability: "actions.review",
            assurance: "ACTIVE_SESSION",
        }
    );
}

#[test]
fn economics_import_human_routes_require_budget_governance_capability() {
    assert!(!economics_import_capabilities_are_satisfied(
        true,
        &["actions.propose".to_owned(), "actions.review".to_owned()],
    ));
    assert!(economics_import_capabilities_are_satisfied(
        true,
        &["budgets.manage".to_owned()],
    ));
    assert!(!economics_import_capabilities_are_satisfied(
        true,
        &["economics.import".to_owned()],
    ));
    assert!(economics_import_capabilities_are_satisfied(
        true,
        &["actions.propose".to_owned(), "budgets.manage".to_owned()],
    ));
}

#[actix_web::test]
async fn invalid_actor_assertion_is_rejected_before_persisted_kind_lookup()
-> Result<(), sqlx::Error> {
    let state = web::Data::new(AppState {
        pool: PgPoolOptions::new().connect_lazy("postgresql://gurine:unused@127.0.0.1:1/gurine")?,
        assertion_keys: KeyRing {
            current: AssertionKey::new([1_u8; 32]),
            previous: None,
        },
        field_keys: EnvelopeKeyRing {
            current: EnvelopeKey::new([2_u8; 32]),
            previous: None,
        },
        domain_events: Mutex::new(InProcessDomainEventJournal::default()),
    });
    let app = actix_test::init_service(App::new().app_data(state).configure(configure)).await;
    let request = actix_test::TestRequest::post()
        .uri(
            "/v1/internal/action-proposals/00000000-0000-4000-8000-000000000001:claim-review",
        )
        .insert_header(("content-type", "application/json"))
        .insert_header(("idempotency-key", "auth-preflight-no-db"))
        .insert_header(("x-gurine-actor-assertion", "not-a-signed-assertion"))
        .set_payload(
            r#"{"assignmentId":"00000000-0000-4000-8000-000000000002","expectedProposalVersion":1,"expectedAssignmentVersion":1,"expectedApprovalDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","actionKind":"TASK"}"#,
        )
        .to_request();

    let response = actix_test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body: Value = actix_test::read_body_json(response).await;
    assert_ne!(
        body.get("code").and_then(Value::as_str),
        Some("DEPENDENCY_UNAVAILABLE")
    );
    Ok(())
}

#[test]
fn unrelated_action_commands_do_not_gain_economics_capabilities() {
    assert!(economics_import_capabilities_are_satisfied(false, &[]));
}

#[test]
fn withdrawals_keep_their_authoritative_generic_authorization_contracts() -> Result<(), &'static str>
{
    for (operation_id, capability, assurance) in [
        (
            "withdrawActionProposal",
            "actions.propose",
            "ACTIVE_SESSION",
        ),
        (
            "withdrawActionDecision",
            "actions.review",
            "conditional-original-decision-assurance",
        ),
    ] {
        let operation = OPERATIONS
            .iter()
            .find(|operation| operation.id == operation_id)
            .ok_or("withdrawal operation missing")?;
        assert_eq!(operation.capability, capability);
        assert_eq!(operation.assurance_level, assurance);
        assert_eq!(
            effective_authorization(operation, br#"{"actionKind":"ECONOMICS_IMPORT"}"#, false),
            EffectiveAuthorization {
                capability,
                assurance,
            }
        );
    }
    Ok(())
}

#[test]
fn named_person_review_selects_capability_and_assurance_independently() -> Result<(), &'static str>
{
    let operation = OPERATIONS
        .iter()
        .find(|operation| operation.id == "submitReview")
        .ok_or("submitReview operation missing")?;
    for body in [
        br#"{"decision":"approve","criteria":{"namedIndividualOverride":{}}}"#.as_slice(),
        br#"{"decision":"APPROVE","criteria":{"namedIndividualOverride":null}}"#.as_slice(),
        br#"{}"#.as_slice(),
        b"not-json".as_slice(),
    ] {
        assert_eq!(
            effective_authorization(operation, body, false),
            EffectiveAuthorization {
                capability: "review.legal",
                assurance: "STEP_UP",
            }
        );
    }
    for body in [br#"{"decision":"approve","criteria":{}}"#.as_slice()] {
        assert_eq!(
            effective_authorization(operation, body, false),
            EffectiveAuthorization {
                capability: "review.editorial",
                assurance: "STEP_UP",
            }
        );
    }
    for body in [
        br#"{"decision":"reject","criteria":{}}"#.as_slice(),
        br#"{"decision":"changes_required","criteria":{}}"#.as_slice(),
    ] {
        assert_eq!(
            effective_authorization(operation, body, false),
            EffectiveAuthorization {
                capability: "review.editorial",
                assurance: "ACTIVE_SESSION",
            }
        );
    }
    Ok(())
}
