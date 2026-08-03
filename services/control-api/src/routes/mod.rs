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

mod problems;

#[cfg(test)]
use problems::service_error_contract;
use problems::{assertion_problem, problem, service_problem};

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
    let proposal_id = request
        .match_info()
        .get("proposalId")
        .and_then(|value| Uuid::parse_str(value).ok());
    let now = OffsetDateTime::now_utc().unix_timestamp();
    // Authenticate the signed, request-bound assertion before consulting the
    // persisted proposal kind.  A valid ECONOMICS_IMPORT request can carry the
    // stronger STEP_UP assertion while its proposal kind is not yet known, so
    // this preflight accepts only the two closed authorization candidates and
    // re-verifies the exact resolved candidate after the lookup.
    let _preflight_claims = verify_before_economics_kind_lookup(
        operation,
        body,
        token,
        &state.assertion_keys,
        &bound_request,
        now,
    )
    .map_err(assertion_problem)?;
    let economics_import_authorization = service::economics_import_authorization_required(
        operation.id,
        proposal_id,
        body,
        &state.pool,
    )
    .await
    .map_err(service_problem)?;
    let authorization = effective_authorization(operation, body, economics_import_authorization);
    let claims = verify_claims(
        token,
        &state.assertion_keys,
        &bound_request,
        ActorExpectation {
            operation: operation.id,
            capability: authorization.capability,
            assurance: authorization.assurance,
            now,
        },
    )
    .map_err(assertion_problem)?;
    if !economics_import_capabilities_are_satisfied(
        economics_import_authorization,
        &claims.capabilities,
    ) {
        return Err(assertion_problem(AssertionError::CapabilityDenied));
    }
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

fn economics_import_capabilities_are_satisfied(
    economics_import_authorization: bool,
    capabilities: &[String],
) -> bool {
    !economics_import_authorization || capabilities.iter().any(|actual| actual == "budgets.manage")
}

fn verify_before_economics_kind_lookup(
    operation: &OperationSpec,
    body: &[u8],
    token: &str,
    keys: &gurine_auth::assertion::service::KeyRing,
    bound_request: &BoundRequest<'_>,
    now: i64,
) -> Result<ActorClaims, AssertionError> {
    let caller_selects_economics = service::caller_selects_economics_import(operation.id, body);
    let generic = effective_authorization(operation, body, false);
    let economics = effective_authorization(operation, body, true);
    if caller_selects_economics {
        return verify_authorization_candidate(
            operation,
            token,
            keys,
            bound_request,
            economics,
            now,
        );
    }
    let generic_result =
        verify_authorization_candidate(operation, token, keys, bound_request, generic, now);
    if generic_result.is_ok()
        || !service::economics_import_kind_may_be_persisted(operation.id)
        || generic == economics
    {
        return generic_result;
    }
    match verify_authorization_candidate(operation, token, keys, bound_request, economics, now) {
        Ok(claims) => Ok(claims),
        Err(_) => generic_result,
    }
}

fn verify_authorization_candidate(
    operation: &OperationSpec,
    token: &str,
    keys: &gurine_auth::assertion::service::KeyRing,
    bound_request: &BoundRequest<'_>,
    authorization: EffectiveAuthorization,
    now: i64,
) -> Result<ActorClaims, AssertionError> {
    verify_claims(
        token,
        keys,
        bound_request,
        ActorExpectation {
            operation: operation.id,
            capability: authorization.capability,
            assurance: authorization.assurance,
            now,
        },
    )
}

fn effective_authorization(
    operation: &OperationSpec,
    body: &[u8],
    economics_import_authorization: bool,
) -> EffectiveAuthorization {
    if economics_import_authorization {
        return EffectiveAuthorization {
            capability: operation.capability,
            assurance: "STEP_UP",
        };
    }
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
        Some(
            "HYPOTHESIS" | "CAPABILITY_ACTIVATION" | "COMMERCIAL_CONTROL" | "ECONOMICS_IMPORT",
        ) => "STEP_UP",
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

#[cfg(test)]
#[path = "authorization_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "error_contract_tests.rs"]
mod error_contract_tests;
