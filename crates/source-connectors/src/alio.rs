use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "alio",
        id: "alio-manifest",
        method: "GET",
        kind: "manifest",
        remote_path: "",
        pagination: "manifest-documents-array",
    },
    ConnectorOperation {
        connector_id: "alio",
        id: "alio-document",
        method: "GET",
        kind: "document",
        remote_path: "",
        pagination: "manifest-order",
    },
];
