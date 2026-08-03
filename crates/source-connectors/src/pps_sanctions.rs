use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "pps-sanctions",
        id: "pps-sanctions-manifest",
        method: "GET",
        kind: "manifest",
        remote_path: "",
        pagination: "manifest-documents-array",
    },
    ConnectorOperation {
        connector_id: "pps-sanctions",
        id: "pps-sanctions-csv",
        method: "GET",
        kind: "document",
        remote_path: "",
        pagination: "manifest-order",
    },
];

/// The connector is deliberately fetch-only until the recorded rights and
/// exact CSV schema gates are satisfied. No guessed CSV normalization exists.
pub const ACTIVATION_STATE: &str = "DISABLED";
pub const NORMALIZATION_BLOCKER: &str = "PPS_SANCTIONS_REUSE_RIGHTS_UNCONFIRMED";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SanctionActivationEvidence {
    pub rights_approved: bool,
    pub schema_fingerprint_approved: bool,
    pub preflight_recorded: bool,
}

pub fn normalized_output_allowed(evidence: SanctionActivationEvidence) -> bool {
    evidence.rights_approved && evidence.schema_fingerprint_approved && evidence.preflight_recorded
}
