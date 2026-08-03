use super::*;

include!("response_addendum.rs");
include!("response_command_projection.rs");
include!("response_materialize.rs");
include!("response_query_projection.rs");

pub(super) fn response_for(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    if operation.success_status == 204 {
        return Ok(Value::Null);
    }
    // BinaryDownload is an authority receipt, not a transport-only three
    // field envelope. Preserve the signed payload bytes and digests emitted
    // by the cost exporter so callers can verify the download before use.
    if operation.id == "exportCostReport" {
        return Ok(data.clone());
    }
    // Addendum responses are closed operation-specific envelopes. They are
    // handled before the legacy OpenAPI materializer because the generated
    // v13.0 document intentionally does not contain v13.1 paths.
    if gurine_api_contracts::addendum::is_control_operation(operation.id) {
        return addendum_response(operation, data);
    }
    let schema = response_schema(operation.id, operation.success_status)?;
    materialize(schema, data, "response")
}
