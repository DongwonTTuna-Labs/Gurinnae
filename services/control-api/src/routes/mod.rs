use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_api_contracts::{OperationSpec, addendum, control_api::OPERATIONS};
use gurine_auth::assertion::{
    AssertionError, BoundRequest,
    actor::{ActorClaims, ActorExpectation, verify_claims},
    canonical::canonical_request_digest,
};
use gurine_persistence_postgres::assertions::{AssertionConsumption, consume};
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{service, state::AppState};

pub fn configure(config: &mut web::ServiceConfig) {
    let list_saved = spec("listSavedViews");
    let create_saved = spec("createSavedView");
    if let (Some(list_saved), Some(create_saved)) = (list_saved, create_saved) {
        config.service(
            web::resource("/v1/internal/saved-views")
                .route(web::get().to(move |r, b, s| handle(list_saved, r, b, s)))
                .route(web::post().to(move |r, b, s| handle(create_saved, r, b, s))),
        );
    } else {
        tracing::error!("generated Control operation catalog is missing saved-view routes");
    }
    // Several operations intentionally share a path (for example GET/POST on
    // the action-proposal queue).  Group methods into one Actix resource so a
    // first resource cannot shadow subsequent methods with a 405.
    let mut grouped: std::collections::BTreeMap<&'static str, Vec<OperationSpec>> =
        std::collections::BTreeMap::new();
    for operation in OPERATIONS
        .iter()
        .chain(addendum::CONTROL_OPERATIONS.iter())
        .chain(addendum::PRIVATE_CONTROL_OPERATIONS.iter())
        .filter(|operation| !operation.path.starts_with("/v1/internal/saved-views"))
    {
        grouped.entry(operation.path).or_default().push(*operation);
    }
    let mut grouped: Vec<_> = grouped.into_iter().collect();
    // Register longer/more-specific patterns first; otherwise Actix's
    // parameterized `/.../{id}` resource captures `/:preview` command paths
    // and returns a misleading 405 before the specific handler is reached.
    grouped.sort_by_key(|(path, _)| std::cmp::Reverse(path.len()));
    for (path, operations) in grouped {
        let mut resource = web::resource(path);
        for operation in operations {
            resource = match operation.method {
                "GET" => resource.route(web::get().to(move |r, b, s| handle(operation, r, b, s))),
                "POST" => resource.route(web::post().to(move |r, b, s| handle(operation, r, b, s))),
                "PATCH" => {
                    resource.route(web::patch().to(move |r, b, s| handle(operation, r, b, s)))
                }
                "DELETE" => {
                    resource.route(web::delete().to(move |r, b, s| handle(operation, r, b, s)))
                }
                _ => resource,
            };
        }
        config.service(resource);
    }
    let update_saved = spec("updateSavedView");
    let delete_saved = spec("deleteSavedView");
    if let (Some(update_saved), Some(delete_saved)) = (update_saved, delete_saved) {
        config.service(
            web::resource("/v1/internal/saved-views/{savedViewId}")
                .route(web::patch().to(move |r, b, s| handle(update_saved, r, b, s)))
                .route(web::delete().to(move |r, b, s| handle(delete_saved, r, b, s))),
        );
    } else {
        tracing::error!(
            "generated Control operation catalog is missing saved-view mutation routes"
        );
    }
}

fn spec(id: &str) -> Option<OperationSpec> {
    OPERATIONS
        .iter()
        .find(|operation| operation.id == id)
        .copied()
}

async fn handle(
    operation: OperationSpec,
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    if let Err(error) = service::reject_direct_provider_control(operation.id) {
        return service_problem(error);
    }
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::new_v4);
    let claims = match authorize(&operation, &request, &body, &state).await {
        Ok(claims) => claims,
        Err(response) => return response,
    };
    match service::execute(
        &operation,
        &request,
        &body,
        &claims,
        &state.pool,
        &state.field_keys,
        &state.domain_events,
        request_id,
    )
    .await
    {
        Ok(output) => {
            let status = StatusCode::from_u16(output.status).unwrap_or(StatusCode::OK);
            let mut response = HttpResponse::build(status);
            response.insert_header(("x-request-id", request_id.to_string()));
            response.insert_header(("x-content-type-options", "nosniff"));
            response.insert_header(("cache-control", "no-store"));
            if output.replay {
                response.insert_header(("idempotent-replay", "true"));
            }
            if output.media_type.is_empty() {
                response.finish()
            } else if output.media_type == "application/json" {
                response.json(output.body)
            } else {
                response
                    .insert_header(("content-type", output.media_type))
                    .body(output.body.as_str().unwrap_or_default().to_owned())
            }
        }
        Err(error) => service_problem(error),
    }
}

fn service_problem(error: service::ServiceError) -> HttpResponse {
    let (code, status) = service_error_contract(&error);
    problem(code, status)
}

fn service_error_contract(error: &service::ServiceError) -> (&'static str, u16) {
    match error {
        service::ServiceError::InvalidRequest => ("INVALID_REQUEST", 400),
        service::ServiceError::NotFound => ("RESOURCE_NOT_FOUND", 404),
        service::ServiceError::VersionConflict => ("VERSION_CONFLICT", 409),
        service::ServiceError::InvalidStateTransition => ("INVALID_STATE_TRANSITION", 409),
        service::ServiceError::PreconditionFailed => ("PRECONDITION_FAILED", 422),
        service::ServiceError::LegalHoldActive => ("LEGAL_HOLD_ACTIVE", 423),
        service::ServiceError::LegalHoldTargetUnsupported => ("LEGAL_HOLD_TARGET_UNSUPPORTED", 422),
        service::ServiceError::IdentityProofInvalid => ("IDENTITY_PROOF_INVALID", 403),
        service::ServiceError::PrivacyScopeInvalid => ("PRIVACY_SCOPE_INVALID", 422),
        service::ServiceError::PrivacyCorrectionTargetUnsupported => {
            ("PRIVACY_CORRECTION_TARGET_UNSUPPORTED", 422)
        }
        service::ServiceError::RetentionVersionConflict => ("RETENTION_VERSION_CONFLICT", 409),
        service::ServiceError::RetentionStateInvalid => ("RETENTION_STATE_INVALID", 409),
        service::ServiceError::BusinessCalendarStale => ("BUSINESS_CALENDAR_STALE", 409),
        service::ServiceError::DependencyUnavailable => ("DEPENDENCY_UNAVAILABLE", 503),
        service::ServiceError::CapabilityDenied => ("CAPABILITY_DENIED", 403),
        service::ServiceError::StepUpRequired => ("STEP_UP_REQUIRED", 403),
        service::ServiceError::ProposalRequired => ("ACTION_PROPOSAL_REQUIRED", 409),
        service::ServiceError::IdempotencyConflict => ("IDEMPOTENCY_CONFLICT", 409),
        service::ServiceError::Persistence => ("INTERNAL_ERROR", 500),
    }
}

async fn authorize(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    state: &AppState,
) -> Result<ActorClaims, HttpResponse> {
    let token = request
        .headers()
        .get("x-gurine-actor-assertion")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| problem("ACTOR_ASSERTION_REQUIRED", 401))?;
    let next_submission_session =
        next_submission_session_header(request).map_err(assertion_problem)?;
    let bound_request = BoundRequest {
        method: request.method().as_str(),
        path: request.path(),
        raw_query: request.query_string(),
        body,
        content_type: request
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok()),
        idempotency_key: request
            .headers()
            .get("idempotency-key")
            .and_then(|value| value.to_str().ok()),
        next_submission_session,
    };
    let authorization = effective_authorization(operation, body);
    let claims = verify_claims(
        token,
        &state.assertion_keys,
        &bound_request,
        ActorExpectation {
            operation: operation.id,
            capability: authorization.capability,
            assurance: authorization.assurance,
            now: OffsetDateTime::now_utc().unix_timestamp(),
        },
    )
    .map_err(assertion_problem)?;
    let request_digest = canonical_request_digest(&bound_request).map_err(assertion_problem)?;
    let consumed = consume(
        &state.pool,
        &AssertionConsumption {
            assertion_type: "ACTOR",
            jti: &claims.jti,
            issuer: &claims.iss,
            audience: &claims.aud,
            expires_at_unix: claims.exp,
            request_digest: &request_digest,
        },
    )
    .await
    .map_err(|_| problem("DEPENDENCY_UNAVAILABLE", 503))?;
    if !consumed {
        return Err(problem("ACTOR_ASSERTION_REPLAYED", 409));
    }
    Ok(claims)
}

fn next_submission_session_header(request: &HttpRequest) -> Result<Option<&str>, AssertionError> {
    let mut values = request
        .headers()
        .get_all("x-gurine-next-submission-session");
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(AssertionError::RequestMismatch);
    }
    let value = value
        .to_str()
        .map_err(|_| AssertionError::RequestMismatch)?;
    if value.len() != 43
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(AssertionError::RequestMismatch);
    }
    Ok(Some(value))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct EffectiveAuthorization {
    capability: &'static str,
    assurance: &'static str,
}

fn effective_authorization(operation: &OperationSpec, body: &[u8]) -> EffectiveAuthorization {
    if operation.id == "submitReview" {
        let Ok(payload) = serde_json::from_slice::<Value>(body) else {
            return EffectiveAuthorization {
                capability: "review.legal",
                assurance: "STEP_UP",
            };
        };
        let Some(criteria) = payload.get("criteria").and_then(Value::as_object) else {
            return EffectiveAuthorization {
                capability: "review.legal",
                assurance: "STEP_UP",
            };
        };
        return if criteria.contains_key("namedIndividualOverride") {
            EffectiveAuthorization {
                capability: "review.legal",
                assurance: "STEP_UP",
            }
        } else {
            let assurance = match payload.get("decision").and_then(Value::as_str) {
                Some("reject" | "REJECT" | "changes_required" | "CHANGES_REQUIRED") => {
                    "ACTIVE_SESSION"
                }
                Some("approve" | "APPROVE") | Some(_) | None => "STEP_UP",
            };
            EffectiveAuthorization {
                capability: "review.editorial",
                assurance,
            }
        };
    }
    if operation.assurance_level != "conditional-by-action-and-decision" {
        return EffectiveAuthorization {
            capability: operation.capability,
            assurance: operation.assurance_level,
        };
    }
    let Ok(payload) = serde_json::from_slice::<Value>(body) else {
        return EffectiveAuthorization {
            capability: operation.capability,
            assurance: "ACTIVE_SESSION",
        };
    };
    let action_kind = payload.get("actionKind").and_then(Value::as_str);
    let decision_kind = payload
        .get("decision")
        .and_then(Value::as_object)
        .and_then(|decision| decision.get("kind"))
        .and_then(Value::as_str);
    if decision_kind != Some("APPROVE") {
        return EffectiveAuthorization {
            capability: operation.capability,
            assurance: "ACTIVE_SESSION",
        };
    }
    let assurance = match action_kind {
        Some("HYPOTHESIS" | "CAPABILITY_ACTIVATION" | "COMMERCIAL_CONTROL") => "STEP_UP",
        Some("PROVIDER_CONTROL") => {
            match payload.get("providerOperationId").and_then(Value::as_str) {
                Some("testProviderConnection") => "ACTIVE_SESSION",
                Some("disableProviderRouting" | "upgradeProviderModel" | "setModelAutoUpgrade") => {
                    "STEP_UP"
                }
                // A malformed or future provider operation must never inherit the
                // connection-test downgrade. The closed request validator rejects
                // it after assertion verification; this boundary first requires
                // the stronger assurance so invalid input cannot lower auth.
                Some(_) | None => "STEP_UP",
            }
        }
        _ => "ACTIVE_SESSION",
    };
    EffectiveAuthorization {
        capability: operation.capability,
        assurance,
    }
}

fn assertion_problem(error: AssertionError) -> HttpResponse {
    match error {
        AssertionError::Expired => problem("ACTOR_ASSERTION_EXPIRED", 401),
        AssertionError::AudienceMismatch => problem("ACTOR_ASSERTION_AUDIENCE_MISMATCH", 401),
        AssertionError::RequestMismatch => problem("ACTOR_ASSERTION_REQUEST_MISMATCH", 401),
        AssertionError::CapabilityDenied => problem("CAPABILITY_DENIED", 403),
        AssertionError::Replayed => problem("ACTOR_ASSERTION_REPLAYED", 409),
        _ => problem("ACTOR_ASSERTION_INVALID", 401),
    }
}

fn problem(code: &str, status: u16) -> HttpResponse {
    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status_code)
        .insert_header(("content-type", "application/problem+json"))
        .json(serde_json::json!({
            "code": code,
            "title": code,
            "status": status,
        }))
}

#[cfg(test)]
mod tests {
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
            pool: PgPoolOptions::new()
                .connect_lazy("postgresql://gurine:unused@127.0.0.1:1/gurine")?,
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
                effective_authorization(&CONDITIONAL_OPERATION, body.as_bytes()).assurance,
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
                effective_authorization(&CONDITIONAL_OPERATION, body).assurance,
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
                effective_authorization(&CONDITIONAL_OPERATION, body.as_bytes()).assurance,
                "ACTIVE_SESSION",
                "wrong assurance for {decision}"
            );
        }
    }

    #[test]
    fn named_person_review_selects_capability_and_assurance_independently()
    -> Result<(), &'static str> {
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
                effective_authorization(operation, body),
                EffectiveAuthorization {
                    capability: "review.legal",
                    assurance: "STEP_UP",
                }
            );
        }
        {
            let body = br#"{"decision":"approve","criteria":{}}"#.as_slice();
            assert_eq!(
                effective_authorization(operation, body),
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
                effective_authorization(operation, body),
                EffectiveAuthorization {
                    capability: "review.editorial",
                    assurance: "ACTIVE_SESSION",
                }
            );
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "error_contract_tests.rs"]
mod error_contract_tests;
