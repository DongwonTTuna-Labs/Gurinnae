#![forbid(unsafe_code)]

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationSpec {
    pub id: &'static str,
    pub api: &'static str,
    pub method: &'static str,
    pub path: &'static str,
    pub auth: &'static str,
    pub capability: &'static str,
    pub idempotency_required: bool,
    pub assurance_level: &'static str,
    pub step_up_required: bool,
    pub operation_kind: &'static str,
    pub success_status: u16,
    pub media_type: &'static str,
    pub response_json: &'static str,
}

/// Addendum v13.1 operation catalog and closed transport metadata.
///
/// The base v13 catalog remains immutable; services explicitly chain this
/// catalog when registering the additive surface. Keeping the catalogs
/// separate prevents an unknown operation from being routed through a
/// generic handler by accident.
pub mod addendum;
pub mod common;
pub mod control;
pub mod control_api;
pub mod event;
pub mod identity;
pub mod identity_provider;
pub mod identity_service_internal;
pub mod openapi;
pub mod problem;
pub mod public;
pub mod public_api;
pub mod submission;
pub mod submission_api;
