use serde_json::{Map, Value};
use thiserror::Error;

static EVENT_SCHEMAS: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/event_schemas.rs"));
static EVENT_PRODUCERS: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/event_producers.rs"));
static OUTBOX_EVENTS: &[&str] = include!(concat!(env!("OUT_DIR"), "/outbox_events.rs"));

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum EventContractError {
    #[error("event type is not in the authority catalog")]
    UnknownType,
    #[error("event payload schema is invalid")]
    InvalidSchema,
    #[error("event payload does not conform to its authority schema")]
    InvalidPayload,
}

pub fn project_payload(event_type: &str, candidates: &Value) -> Result<Value, EventContractError> {
    let schema = schema(event_type)?;
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .ok_or(EventContractError::InvalidSchema)?;
    let source = candidates
        .as_object()
        .ok_or(EventContractError::InvalidPayload)?;
    let mut output = Map::new();
    for name in properties.keys() {
        if let Some(value) = candidate(source, name) {
            output.insert(name.clone(), value.clone());
        }
    }
    let value = Value::Object(output);
    validate_schema(&schema, &value)?;
    Ok(value)
}

pub fn validate_payload(event_type: &str, payload: &Value) -> Result<(), EventContractError> {
    validate_schema(&schema(event_type)?, payload)
}

pub fn event_types() -> impl Iterator<Item = &'static str> {
    EVENT_SCHEMAS.iter().map(|(name, _)| *name)
}

pub fn producer_events(operation_id: &str) -> impl Iterator<Item = &'static str> + '_ {
    EVENT_PRODUCERS
        .iter()
        .filter_map(move |(operation, event)| (*operation == operation_id).then_some(*event))
}

pub fn requires_outbox(event_type: &str) -> bool {
    OUTBOX_EVENTS.contains(&event_type)
}

fn schema(event_type: &str) -> Result<Value, EventContractError> {
    let text = EVENT_SCHEMAS
        .iter()
        .find_map(|(name, schema)| (*name == event_type).then_some(*schema))
        .ok_or(EventContractError::UnknownType)?;
    serde_json::from_str(text).map_err(|_| EventContractError::InvalidSchema)
}

fn candidate<'a>(source: &'a Map<String, Value>, name: &str) -> Option<&'a Value> {
    source
        .get(name)
        .or_else(|| source.get(&snake_to_camel(name)))
        .or_else(|| source.get(&camel_to_snake(name)))
}

fn validate_schema(schema: &Value, value: &Value) -> Result<(), EventContractError> {
    if let Some(options) = schema.get("anyOf").and_then(Value::as_array) {
        if options
            .iter()
            .any(|item| validate_schema(item, value).is_ok())
        {
            return Ok(());
        }
        return Err(EventContractError::InvalidPayload);
    }
    if let Some(expected) = schema.get("const")
        && expected != value
    {
        return Err(EventContractError::InvalidPayload);
    }
    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && !values.contains(value)
    {
        return Err(EventContractError::InvalidPayload);
    }
    let kind = schema.get("type").and_then(Value::as_str);
    match kind {
        Some("object") => validate_object(schema, value)?,
        Some("array") => {
            let items = value.as_array().ok_or(EventContractError::InvalidPayload)?;
            if let Some(item_schema) = schema.get("items") {
                for item in items {
                    validate_schema(item_schema, item)?;
                }
            }
        }
        Some("string") => validate_string(schema, value)?,
        Some("integer") if value.as_i64().is_none() && value.as_u64().is_none() => {
            return Err(EventContractError::InvalidPayload);
        }
        Some("number") if !value.is_number() => return Err(EventContractError::InvalidPayload),
        Some("boolean") if !value.is_boolean() => return Err(EventContractError::InvalidPayload),
        Some("null") if !value.is_null() => return Err(EventContractError::InvalidPayload),
        _ => {}
    }
    Ok(())
}

fn validate_object(schema: &Value, value: &Value) -> Result<(), EventContractError> {
    let object = value
        .as_object()
        .ok_or(EventContractError::InvalidPayload)?;
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .ok_or(EventContractError::InvalidSchema)?;
    if schema.get("additionalProperties") == Some(&Value::Bool(false))
        && object.keys().any(|key| !properties.contains_key(key))
    {
        return Err(EventContractError::InvalidPayload);
    }
    for required in schema
        .get("required")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        if !object.contains_key(required) {
            return Err(EventContractError::InvalidPayload);
        }
    }
    for (name, item) in object {
        validate_schema(
            properties
                .get(name)
                .ok_or(EventContractError::InvalidPayload)?,
            item,
        )?;
    }
    Ok(())
}

fn validate_string(schema: &Value, value: &Value) -> Result<(), EventContractError> {
    let text = value.as_str().ok_or(EventContractError::InvalidPayload)?;
    if schema
        .get("minLength")
        .and_then(Value::as_u64)
        .is_some_and(|v| text.chars().count() < v as usize)
        || schema
            .get("maxLength")
            .and_then(Value::as_u64)
            .is_some_and(|v| text.chars().count() > v as usize)
    {
        return Err(EventContractError::InvalidPayload);
    }
    match schema.get("format").and_then(Value::as_str) {
        Some("uuid") if !uuid_shape(text) => return Err(EventContractError::InvalidPayload),
        Some("date-time")
            if !(text.contains('T') && (text.ends_with('Z') || text.contains('+'))) =>
        {
            return Err(EventContractError::InvalidPayload);
        }
        Some("date") if text.len() != 10 => return Err(EventContractError::InvalidPayload),
        _ => {}
    }
    if let Some(pattern) = schema.get("pattern").and_then(Value::as_str) {
        let valid = if pattern.contains("[a-f0-9]{64}") {
            text.len() == 64
                && text
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        } else if pattern.contains("[A-Za-z0-9_-") {
            text.bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        } else {
            !text.is_empty()
        };
        if !valid {
            return Err(EventContractError::InvalidPayload);
        }
    }
    Ok(())
}

fn uuid_shape(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn snake_to_camel(value: &str) -> String {
    let mut output = String::new();
    let mut uppercase = false;
    for character in value.chars() {
        if character == '_' {
            uppercase = true;
        } else if uppercase {
            output.extend(character.to_uppercase());
            uppercase = false;
        } else {
            output.push(character);
        }
    }
    output
}

fn camel_to_snake(value: &str) -> String {
    let mut output = String::new();
    for character in value.chars() {
        if character.is_ascii_uppercase() {
            output.push('_');
            output.push(character.to_ascii_lowercase());
        } else {
            output.push(character);
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn projects_aliases_and_rejects_extra_or_missing_fields() {
        let candidates = json!({
            "actorId":"11111111-1111-4111-8111-111111111111",
            "occurredAt":"2026-07-12T00:00:00Z",
            "operationId":"grantRole",
            "requestId":"22222222-2222-4222-8222-222222222222",
            "roleId":"33333333-3333-4333-8333-333333333333",
            "userId":"44444444-4444-4444-8444-444444444444",
            "secret":"not emitted"
        });
        let payload = project_payload("access.role_granted.v1", &candidates).expect("valid event");
        assert!(payload.get("secret").is_none());
        validate_payload("access.role_granted.v1", &payload).expect("schema valid");
        assert_eq!(event_types().count(), 99);
        assert_eq!(producer_events("publishCase").count(), 3);
        assert!(requires_outbox(
            "projection.publication_revision_created.v1"
        ));
        assert!(!requires_outbox("publication.revision_created.v1"));
    }
}
