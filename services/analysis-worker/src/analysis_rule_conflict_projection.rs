use serde_json::{Map, Value, json};

use super::{Failure, materialization_invalid};

pub(super) fn award_winner_for_notice(
    frozen: &Value,
    notice_id: &Value,
) -> Result<Option<Value>, Failure> {
    let mut winners = Vec::new();
    for row in frozen_array(frozen, "procurement_awards")? {
        let row = object(row, "procurement_awards")?;
        if row.get("notice_id") == Some(notice_id)
            && let Some(values) = row.get("supplier_ids").and_then(Value::as_array)
        {
            winners.extend(values.iter().cloned());
        }
    }
    Ok(exact_value(&winners).cloned())
}

pub(super) fn revolving_contracts(frozen: &Value) -> Result<Vec<Value>, Failure> {
    frozen_array(frozen, "contracts")?
        .iter()
        .map(|row| {
            let row = object(row, "contracts")?;
            Ok(json!({
                "id": field(row,"id"),
                "agency_id": field(row,"agency_id"),
                "supplier_id": field(row,"supplier_id"),
                "signed_on": field(row,"signed_on"),
                "procurement_method": field(row,"procurement_method"),
            }))
        })
        .collect()
}

pub(super) fn former_official_roles(rows: &[Value]) -> Result<Vec<Value>, Failure> {
    relationship_roles(rows, "FORMER_OFFICIAL_ROLE", "AGENCY")
}

pub(super) fn supplier_officer_roles(rows: &[Value]) -> Result<Vec<Value>, Failure> {
    relationship_roles(rows, "MANAGEMENT_ROLE", "SUPPLIER")
}

fn relationship_roles(
    rows: &[Value],
    relationship_kind: &str,
    object_kind: &str,
) -> Result<Vec<Value>, Failure> {
    let mut output = Vec::new();
    for row in rows {
        let row = object(row, "typed_relationship_assertions")?;
        if field_text(row, "relationship_kind") != Some(relationship_kind)
            || field_text(row, "subject_kind") != Some("PERSON")
            || field_text(row, "object_kind") != Some(object_kind)
        {
            continue;
        }
        let mut role = Map::new();
        for key in [
            "relationship_id",
            "relationship_kind",
            "subject_kind",
            "object_kind",
            "person_identifier_digest",
            "valid_from",
            "valid_to",
            "validity_coverage_status",
            "verification_status",
            "public_use_status",
            "independent_human_verification",
            "source_kind",
        ] {
            role.insert(key.to_owned(), field(row, key));
        }
        role.insert(
            "evidence_id".to_owned(),
            first_array_value(row, "evidence_ids"),
        );
        role.insert(
            "source_locator".to_owned(),
            first_digest_array_value(row, "source_locators")?,
        );
        if object_kind == "AGENCY" {
            role.insert("agency_id".to_owned(), field(row, "object_entity_id"));
            role.insert("departed_on".to_owned(), field(row, "departed_on"));
        } else {
            role.insert("supplier_id".to_owned(), field(row, "object_entity_id"));
        }
        output.push(Value::Object(role));
    }
    Ok(output)
}

pub(super) fn sanctioned_rows(frozen: &Value) -> Result<Vec<Value>, Failure> {
    frozen_array(frozen, "sanctions")?
        .iter()
        .map(|row| {
            let row = object(row, "sanctions")?;
            Ok(json!({
                "id": field(row,"id"),
                "supplier_id": field(row,"supplier_id"),
                "effective_from": field(row,"effective_from"),
                "effective_to": field(row,"effective_to"),
                "source_status": field(row,"source_status"),
                "coverage_status": field(row,"coverage_status"),
            }))
        })
        .collect()
}

pub(super) fn sanctioned_suppliers(frozen: &Value) -> Result<Vec<Value>, Failure> {
    frozen_array(frozen, "suppliers")?
        .iter()
        .map(|row| {
            let row = object(row, "suppliers")?;
            Ok(json!({
                "id": field(row,"id"),
                "incorporated_at": field(row,"incorporated_at"),
            }))
        })
        .collect()
}

pub(super) fn sanctioned_awards(frozen: &Value) -> Result<Vec<Value>, Failure> {
    let mut output = Vec::new();
    for row in frozen_array(frozen, "procurement_awards")? {
        let row = object(row, "procurement_awards")?;
        let Some(supplier) = row
            .get("supplier_ids")
            .and_then(Value::as_array)
            .and_then(|values| exact_value(values))
        else {
            continue;
        };
        output.push(json!({
            "id": field(row,"id"),
            "supplier_id": supplier,
            "awarded_at": field(row,"awarded_on"),
        }));
    }
    Ok(output)
}

pub(super) fn strong_identifier_facts(frozen: &Value) -> Result<Vec<Value>, Failure> {
    frozen_array(frozen, "strong_identifier_facts")?
        .iter()
        .filter(|row| {
            row.get("verification_status").and_then(Value::as_str) == Some("VERIFIED")
                && row.get("proof_state").and_then(Value::as_str) == Some("PROVEN_V1")
                && matches!(
                    row.get("scheme").and_then(Value::as_str),
                    Some("KOREAN_BUSINESS_NUMBER" | "OPEN_DART_CORP_CODE" | "KONEPS_PARTY_KEY")
                )
        })
        .map(|row| {
            let row = object(row, "strong_identifier_facts")?;
            Ok(json!({
                "supplier_id": field(row,"supplier_id"),
                "scheme": field(row,"scheme"),
                "value_hash": field(row,"value_hash"),
                "verification_status": field(row,"verification_status"),
                "proof_state": field(row,"proof_state"),
            }))
        })
        .collect()
}

pub(super) fn frozen_array<'a>(frozen: &'a Value, key: &str) -> Result<&'a Vec<Value>, Failure> {
    frozen
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| materialization_invalid(key))
}

pub(super) fn coverage(frozen: &Value, key: &str) -> Result<bool, Failure> {
    coverage_value(frozen, key)?
        .as_bool()
        .ok_or_else(|| materialization_invalid(key))
}

pub(super) fn coverage_value(frozen: &Value, key: &str) -> Result<Value, Failure> {
    frozen
        .get("coverage")
        .and_then(Value::as_object)
        .and_then(|coverage| coverage.get(key))
        .cloned()
        .ok_or_else(|| materialization_invalid(key))
}

pub(super) fn exact_row<'a>(rows: &'a [Value], detail: &str) -> Result<Option<&'a Value>, Failure> {
    match rows {
        [] => Ok(None),
        [row] => Ok(Some(row)),
        _ => Err(materialization_invalid(&format!("ambiguous {detail}"))),
    }
}

pub(super) fn exact_value(values: &[Value]) -> Option<&Value> {
    match values {
        [value] => Some(value),
        _ => None,
    }
}

pub(super) fn object<'a>(
    value: &'a Value,
    detail: &str,
) -> Result<&'a Map<String, Value>, Failure> {
    value
        .as_object()
        .ok_or_else(|| materialization_invalid(detail))
}

pub(super) fn field(row: &Map<String, Value>, key: &str) -> Value {
    row.get(key).cloned().unwrap_or(Value::Null)
}

pub(super) fn field_text<'a>(row: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str)
}

fn first_array_value(row: &Map<String, Value>, key: &str) -> Value {
    row.get(key)
        .and_then(Value::as_array)
        .and_then(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .min()
                .map(|value| Value::String(value.to_owned()))
        })
        .unwrap_or(Value::Null)
}

fn first_digest_array_value(row: &Map<String, Value>, key: &str) -> Result<Value, Failure> {
    let Some(values) = row.get(key).and_then(Value::as_array) else {
        return Ok(Value::Null);
    };
    let digests = values
        .iter()
        .map(Value::as_str)
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| materialization_invalid(key))?;
    if digests.iter().any(|value| !is_lower_sha256(value)) {
        return Err(materialization_invalid(key));
    }
    Ok(digests
        .into_iter()
        .min()
        .map(|value| Value::String(value.to_owned()))
        .unwrap_or(Value::Null))
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

pub(super) fn required_values(row: &Map<String, Value>, keys: &[&str]) -> bool {
    keys.iter().all(|key| row.get(*key).is_some_and(non_null))
}

pub(super) fn non_null(value: &Value) -> bool {
    !value.is_null()
}

pub(super) fn approved_relationship(row: &Map<String, Value>) -> bool {
    field_text(row, "verification_status") == Some("VERIFIED")
        && field_text(row, "public_use_status") == Some("APPROVED")
        && row
            .get("independent_human_verification")
            .and_then(Value::as_bool)
            == Some(true)
}

pub(super) fn decimal_as_string(value: &Value) -> Value {
    match value {
        Value::Number(number) => Value::String(number.to_string()),
        _ => value.clone(),
    }
}
