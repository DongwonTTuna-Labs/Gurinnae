struct ContractSummaryRow {
    id: Uuid,
    contract_number: Option<String>,
    title: String,
    agency_id: Option<Uuid>,
    supplier_id: Option<Uuid>,
    status: String,
    signed_at: Option<Date>,
    amount: Option<Value>,
    agency_name: Option<String>,
    supplier_name: Option<String>,
}

fn contract_summary(row: ContractSummaryRow) -> Result<Value, ServiceError> {
    let ContractSummaryRow {
        id,
        contract_number,
        title,
        agency_id,
        supplier_id,
        status,
        signed_at,
        amount,
        agency_name,
        supplier_name,
    } = row;
    let mut value = json!({
        "id": id,
        "contractNumber": contract_number.unwrap_or_default(),
        "title": title,
        "agency": entity_ref(agency_id, agency_name, "AGENCY"),
        "status": status,
        "interpretationNotice": OPERATIONAL_INTERPRETATION_NOTICE,
        "href": format!("/contracts/{id}"),
    });
    if let Some(supplier) = supplier_id {
        value["supplier"] = entity_ref(Some(supplier), supplier_name, "SUPPLIER");
    }
    if let Some(date) = signed_at {
        value["signedAt"] = Value::String(date.to_string());
    }
    if let Some(amount) = amount {
        value["amount"] = amount;
    }
    Ok(value)
}

struct RuleRow {
    rule_id: String,
    name: String,
    active_version: String,
    public_description: String,
    requirements: Value,
    exclusions: Value,
    limitations: Value,
    updated_at: OffsetDateTime,
}

struct SourceRow {
    source_id: String,
    display_name: String,
    status: String,
    last_success_at: Option<OffsetDateTime>,
    lag_seconds: Option<i64>,
    affected_scope: Value,
    public_message: Option<String>,
}

struct SourceDetailRow {
    display_name: String,
    status: String,
    updated_at: OffsetDateTime,
    official_url: Option<String>,
}

fn entity_ref(id: Option<Uuid>, name: Option<String>, kind: &str) -> Value {
    match id {
        Some(id) => json!({
            "id": id,
            "name": name,
            "entityType": kind,
            "href": if kind == "AGENCY" { format!("/agencies/{id}") } else { format!("/suppliers/{id}") },
        }),
        None => json!({
            "id": "unresolved",
            "name": name.unwrap_or_else(|| "미확인".to_owned()),
            "entityType": kind,
            "href": "",
        }),
    }
}

#[cfg(test)]
mod entity_ref_tests {
    use super::*;

    #[test]
    fn anonymized_entity_ref_preserves_identity_and_uses_null_name() {
        let id = Uuid::nil();
        let reference = entity_ref(Some(id), None, "AGENCY");

        assert_eq!(reference["id"], json!(id));
        assert_eq!(reference["name"], Value::Null);
        assert_eq!(reference["entityType"], "AGENCY");
        assert_eq!(reference["href"], format!("/agencies/{id}"));
    }
}
