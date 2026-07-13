use crate::ConnectorOperation;

pub const OPERATIONS: &[ConnectorOperation] = &[
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-corp-code",
        method: "GET",
        kind: "snapshot-zip-xml",
        remote_path: "/corpCode.xml",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-company",
        method: "GET",
        kind: "detail",
        remote_path: "/company.json",
        pagination: "none",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-disclosures",
        method: "GET",
        kind: "list",
        remote_path: "/list.json",
        pagination: "page-number",
    },
    ConnectorOperation {
        connector_id: "open-dart",
        id: "dart-financial-statements",
        method: "GET",
        kind: "list",
        remote_path: "/fnlttSinglAcntAll.json",
        pagination: "none",
    },
];
