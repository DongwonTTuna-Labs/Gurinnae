use gurine_api_contracts::OperationSpec;
use serde_json::Value;
use thiserror::Error;

#[derive(Debug)]
pub struct OperationInput<'a> {
    pub request_id: &'a str,
    pub method: &'a str,
    pub path_and_query: &'a str,
    pub content_type: Option<&'a str>,
    pub idempotency_key: Option<&'a str>,
    pub body: &'a [u8],
}

#[derive(Debug)]
pub struct OperationOutput {
    pub status: u16,
    pub media_type: &'static str,
    pub body: Value,
}

#[derive(Debug, Error)]
pub enum OperationError {
    #[error("request method does not match the operation contract")]
    MethodMismatch,
    #[error("idempotency key is required")]
    IdempotencyRequired,
    #[error("request body is not valid JSON")]
    InvalidJson,
    #[error("generated response contract is invalid")]
    InvalidResponseContract,
}

pub fn execute(
    operation: &OperationSpec,
    input: &OperationInput<'_>,
) -> Result<OperationOutput, OperationError> {
    if input.method != operation.method {
        return Err(OperationError::MethodMismatch);
    }
    if operation.idempotency_required && input.idempotency_key.is_none() {
        return Err(OperationError::IdempotencyRequired);
    }
    if !input.body.is_empty() && serde_json::from_slice::<Value>(input.body).is_err() {
        return Err(OperationError::InvalidJson);
    }
    let mut response: Value = serde_json::from_str(operation.response_json)
        .map_err(|_| OperationError::InvalidResponseContract)?;
    if let Some(object) = response.as_object_mut() {
        if object.contains_key("requestId") {
            object.insert(
                "requestId".to_owned(),
                Value::String(input.request_id.to_owned()),
            );
        }
        if object.contains_key("operationId") {
            object.insert(
                "operationId".to_owned(),
                Value::String(operation.id.to_owned()),
            );
        }
    }
    Ok(OperationOutput {
        status: operation.success_status,
        media_type: operation.media_type,
        body: response,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idempotency_is_enforced_before_execution() {
        let operation = OperationSpec {
            id: "write",
            api: "test",
            method: "POST",
            path: "/write",
            auth: "none",
            capability: "",
            idempotency_required: true,
            operation_kind: "COMMAND",
            assurance_level: "ANONYMOUS_PROOF",
            step_up_required: false,
            success_status: 202,
            media_type: "application/json",
            response_json: "{}",
        };
        let input = OperationInput {
            request_id: "request",
            method: "POST",
            path_and_query: "/write",
            content_type: Some("application/json"),
            idempotency_key: None,
            body: b"{}",
        };
        assert!(matches!(
            execute(&operation, &input),
            Err(OperationError::IdempotencyRequired)
        ));
    }
}
