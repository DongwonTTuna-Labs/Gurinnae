use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "local-finance",
        id: "local-finance-disclosures",
        method: "GET",
        kind: "official-link-entry",
        remote_path: "",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "local-finance",
        id: "local-finance-subsidies",
        method: "GET",
        kind: "official-link-entry",
        remote_path: "",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "local-finance",
        id: "local-finance-statistics",
        method: "GET",
        kind: "official-link-entry",
        remote_path: "",
        pagination: "none",
    },
];
