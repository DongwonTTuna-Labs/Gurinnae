#![forbid(unsafe_code)]

pub mod alio;
pub mod audit_results;
pub mod data_go_kr;
pub mod koneps;
pub mod local_finance;
pub mod open_dart;
pub mod request;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConnectorOperation {
    pub connector_id: &'static str,
    pub id: &'static str,
    pub method: &'static str,
    pub kind: &'static str,
    pub remote_path: &'static str,
    pub pagination: &'static str,
}

pub fn operations() -> impl Iterator<Item = &'static ConnectorOperation> {
    alio::OPERATIONS
        .iter()
        .chain(audit_results::OPERATIONS)
        .chain(koneps::OPERATIONS)
        .chain(local_finance::OPERATIONS)
        .chain(open_dart::OPERATIONS)
}
