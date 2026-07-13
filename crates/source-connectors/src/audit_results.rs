use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "audit-results",
        id: "audit-results-manifest",
        method: "GET",
        kind: "manifest",
        remote_path: "",
        pagination: "manifest-documents-array",
    },
    ConnectorOperation {
        connector_id: "audit-results",
        id: "audit-result-document",
        method: "GET",
        kind: "document",
        remote_path: "",
        pagination: "manifest-order",
    },
];
