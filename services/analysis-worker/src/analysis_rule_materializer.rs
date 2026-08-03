use std::collections::{BTreeMap, BTreeSet};

use rust_decimal::Decimal;
use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::{Failure, canonical_bytes, sha256};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct SnapshotMember {
    pub ordinal: i64,
    pub member_digest: String,
    pub object_type: String,
    pub object_id: Uuid,
    pub object_version: i64,
    pub canonical_payload: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct StrongIdentifierFact {
    pub supplier_id: Uuid,
    pub scheme: String,
    pub value_hash: String,
    pub verification_status: String,
    pub proof_state: String,
}

#[derive(Debug)]
pub(super) struct MaterializedRuleInput {
    pub value: Value,
    pub input_sha256: String,
}

pub(super) fn materialize_rule_input(
    rule_id: &str,
    configuration: &Value,
    members: &[SnapshotMember],
    identifier_facts: &[StrongIdentifierFact],
) -> Result<MaterializedRuleInput, Failure> {
    let ordered = ordered_members(members)?;
    let value = match rule_id {
        "PRICE_OUTLIER" => price_outlier(&ordered)?,
        "CONTRACT_SPLITTING_PATTERN" => json!({
            "contracts": contract_inputs(&ordered)?,
            "single_source_threshold": krw_config_value(configuration, "singleSourceThreshold")?,
            "window_days": config_value(configuration, "windowDays"),
        }),
        "REPEATED_SINGLE_SOURCE" => json!({
            "contracts": contract_inputs(&ordered)?,
            "window_days": config_value(configuration, "windowDays"),
        }),
        "SUPPLIER_CONCENTRATION" => json!({
            "contracts": contract_inputs(&ordered)?,
            "minimum_total_spend": krw_config_value(configuration, "minimumTotalSpend")?,
        }),
        "LOW_BID_COMPETITION" => low_bid_competition(&ordered)?,
        "CONTRACT_AMENDMENT_ESCALATION" => contract_amendment(&ordered)?,
        "YEAR_END_SPENDING_SPIKE" => year_end_spending(&ordered)?,
        "NEW_SUPPLIER_DEPENDENCE" => new_supplier_dependence(&ordered)?,
        "SHARED_SUPPLIER_IDENTITY" => shared_supplier_identity(&ordered, identifier_facts)?,
        "RESTRICTIVE_SPECIFICATION" => restrictive_specification(&ordered)?,
        _ => {
            return Err(Failure::Terminal(
                "RULE_INPUT_MATERIALIZATION_UNSUPPORTED",
                rule_id.to_owned(),
            ));
        }
    };
    let input_sha256 = sha256(&canonical_bytes(&value)?);
    Ok(MaterializedRuleInput {
        value,
        input_sha256,
    })
}

fn ordered_members(members: &[SnapshotMember]) -> Result<Vec<&SnapshotMember>, Failure> {
    let mut ordered = members.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| {
        (left.ordinal, left.member_digest.as_str())
            .cmp(&(right.ordinal, right.member_digest.as_str()))
    });
    let mut ordinals = BTreeSet::new();
    let mut digests = BTreeSet::new();
    for member in &ordered {
        if member.ordinal < 0
            || !ordinals.insert(member.ordinal)
            || !digests.insert(member.member_digest.as_str())
        {
            return Err(materialization_invalid("snapshot member ordering"));
        }
        validate_member_binding(member)?;
    }
    Ok(ordered)
}

fn validate_member_binding(member: &SnapshotMember) -> Result<(), Failure> {
    let payload = member
        .canonical_payload
        .as_object()
        .ok_or_else(|| materialization_invalid("canonicalPayload"))?;
    if payload.get("objectType").and_then(Value::as_str) != Some(member.object_type.as_str())
        || payload
            .get("objectId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            != Some(member.object_id)
        || payload.get("objectVersion").and_then(Value::as_i64) != Some(member.object_version)
    {
        return Err(materialization_invalid("snapshot member binding"));
    }
    Ok(())
}

fn contract_inputs(members: &[&SnapshotMember]) -> Result<Vec<Value>, Failure> {
    let mut categories = BTreeMap::<String, BTreeSet<String>>::new();
    for member in members
        .iter()
        .filter(|member| member.object_type == "CONTRACT_LINE_ITEM")
    {
        let Some(payload) = member.canonical_payload.as_object() else {
            continue;
        };
        let Some(contract_id) = payload.get("contractId").and_then(Value::as_str) else {
            continue;
        };
        let Some(category) = payload
            .get("normalizedCategory")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        else {
            continue;
        };
        categories
            .entry(contract_id.to_owned())
            .or_default()
            .insert(category.to_owned());
    }
    members
        .iter()
        .filter(|member| member.object_type == "CONTRACT")
        .map(|member| {
            let related_category = categories
                .get(&member.object_id.to_string())
                .filter(|values| values.len() == 1)
                .and_then(|values| values.first())
                .map(|value| Value::String(value.clone()));
            contract_input(member, related_category.as_ref())
        })
        .collect()
}

fn contract_input(
    member: &SnapshotMember,
    related_category: Option<&Value>,
) -> Result<Value, Failure> {
    let payload = payload(member)?;
    let mut contract = Map::new();
    contract.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_field(payload, &mut contract, "agencyId", "agency_id");
    copy_field(payload, &mut contract, "supplierId", "supplier_id");
    copy_field(payload, &mut contract, "normalizedCategory", "category");
    if contract.get("category").is_none_or(Value::is_null)
        && let Some(category) = related_category
    {
        contract.insert("category".to_owned(), category.clone());
    }
    copy_field(payload, &mut contract, "signedAt", "signed_at");
    copy_krw_field(payload, &mut contract, "currentAmount", "amount")?;
    copy_field(payload, &mut contract, "procurementMethod", "method");
    copy_field(
        payload,
        &mut contract,
        "legitimatePhase",
        "legitimate_phase",
    );
    Ok(Value::Object(contract))
}

fn price_outlier(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let observations = members
        .iter()
        .filter(|member| member.object_type == "PRICE_OBSERVATION")
        .copied()
        .collect::<Vec<_>>();
    let Some(target) = unique_target(&observations, "PRICE_OBSERVATION")? else {
        return Ok(json!({"target": Value::Null, "comparables": []}));
    };
    Ok(json!({"target": price_observation(target)?, "comparables": []}))
}

fn price_observation(member: &SnapshotMember) -> Result<Value, Failure> {
    let payload = payload(member)?;
    let mut observation = Map::new();
    observation.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_krw_field(payload, &mut observation, "unitPrice", "unit_price")?;
    copy_field(payload, &mut observation, "unit", "unit");
    copy_field(payload, &mut observation, "normalizedCategory", "category");
    copy_field(payload, &mut observation, "vatIncluded", "vat_included");
    copy_field(payload, &mut observation, "bundleKnown", "bundle_known");
    copy_field(payload, &mut observation, "observedAt", "observed_at");
    copy_field(payload, &mut observation, "sourceKey", "source_key");
    Ok(Value::Object(observation))
}

fn low_bid_competition(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let candidates = members
        .iter()
        .filter(|member| member.object_type == "CONTRACT")
        .copied()
        .collect::<Vec<_>>();
    let Some(member) = unique_target(&candidates, "CONTRACT")? else {
        return Ok(json!({"procurement": Value::Null}));
    };
    let payload = payload(member)?;
    let mut procurement = Map::new();
    procurement.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_field(payload, &mut procurement, "procurementMethod", "method");
    copy_field(
        payload,
        &mut procurement,
        "validBidderCount",
        "valid_bidder_count",
    );
    copy_krw_field(
        payload,
        &mut procurement,
        "estimatedAmount",
        "estimated_amount",
    )?;
    copy_field(payload, &mut procurement, "emergency", "emergency");
    Ok(json!({"procurement": procurement}))
}

fn contract_amendment(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let candidates = members
        .iter()
        .filter(|member| member.object_type == "CONTRACT")
        .copied()
        .collect::<Vec<_>>();
    let Some(member) = unique_target(&candidates, "CONTRACT")? else {
        return Ok(json!({"contract": Value::Null}));
    };
    let payload = payload(member)?;
    let mut contract = Map::new();
    contract.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_krw_field(payload, &mut contract, "originalAmount", "original_amount")?;
    copy_krw_field(payload, &mut contract, "currentAmount", "final_amount")?;
    copy_field(payload, &mut contract, "amendmentCount", "amendment_count");
    copy_field(
        payload,
        &mut contract,
        "scopeChangeExplained",
        "scope_change_explained",
    );
    Ok(json!({"contract": contract}))
}

fn year_end_spending(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let contracts = contract_inputs(members)?;
    let mut spends = [Decimal::ZERO; 12];
    let mut counts = [0_i64; 12];
    for contract in &contracts {
        let Some(month) = contract
            .get("signed_at")
            .and_then(Value::as_str)
            .and_then(month_index)
        else {
            continue;
        };
        let Some(amount) = contract.get("amount").and_then(decimal_value) else {
            continue;
        };
        spends[month] += amount;
        counts[month] += 1;
    }
    Ok(json!({
        "monthly_spend": spends.map(|value| value.to_string()),
        "monthly_contract_count": counts,
    }))
}

fn month_index(date: &str) -> Option<usize> {
    let bytes = date.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let year = date[0..4].parse::<i32>().ok()?;
    let month = date[5..7].parse::<u8>().ok()?;
    let day = date[8..10].parse::<u8>().ok()?;
    let month_value = time::Month::try_from(month).ok()?;
    time::Date::from_calendar_date(year, month_value, day).ok()?;
    Some(usize::from(month - 1))
}

fn decimal_value(value: &Value) -> Option<Decimal> {
    match value {
        Value::Number(number) => number.to_string().parse().ok(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

fn new_supplier_dependence(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let suppliers = members
        .iter()
        .filter(|member| member.object_type == "SUPPLIER")
        .copied()
        .collect::<Vec<_>>();
    let Some(member) = unique_target(&suppliers, "SUPPLIER")? else {
        return Ok(json!({"supplier": Value::Null}));
    };
    let payload = payload(member)?;
    let mut supplier = Map::new();
    supplier.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_field(payload, &mut supplier, "ageDays", "age_days");
    copy_field(
        payload,
        &mut supplier,
        "agencyContractCount",
        "agency_contract_count",
    );
    copy_krw_field(payload, &mut supplier, "agencySpend", "agency_spend")?;
    copy_krw_field(
        payload,
        &mut supplier,
        "totalPublicSpend",
        "total_public_spend",
    )?;
    supplier.insert(
        "identity_verified".to_owned(),
        Value::Bool(payload.get("identityStatus").and_then(Value::as_str) == Some("VERIFIED")),
    );
    Ok(json!({"supplier": supplier}))
}

fn shared_supplier_identity(
    members: &[&SnapshotMember],
    identifier_facts: &[StrongIdentifierFact],
) -> Result<Value, Failure> {
    let hashes = strong_hashes(identifier_facts);
    let suppliers = hashes
        .into_iter()
        .map(|(supplier_id, strong_identifier_hashes)| {
            json!({
                "id": supplier_id,
                "strong_identifier_hashes": strong_identifier_hashes,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "suppliers": suppliers,
        "contracts": contract_inputs(members)?,
    }))
}

fn strong_hashes(facts: &[StrongIdentifierFact]) -> BTreeMap<Uuid, Vec<String>> {
    let mut by_supplier: BTreeMap<Uuid, BTreeSet<String>> = BTreeMap::new();
    for fact in facts {
        if fact.verification_status != "VERIFIED" || fact.proof_state != "PROVEN_V1" {
            continue;
        }
        let canonical_scheme = match fact.scheme.as_str() {
            "KOREAN_BUSINESS_NUMBER" => "KOREAN_BUSINESS_NUMBER",
            "OPEN_DART_CORP_CODE" => "OPEN_DART_CORP_CODE",
            "KONEPS_PARTY_KEY" => "KONEPS_PARTY_KEY",
            _ => continue,
        };
        let value_hash = fact.value_hash.trim();
        if value_hash.len() != 64
            || !value_hash
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            continue;
        }
        by_supplier
            .entry(fact.supplier_id)
            .or_default()
            .insert(format!("{canonical_scheme}:{value_hash}"));
    }
    by_supplier
        .into_iter()
        .map(|(supplier, hashes)| (supplier, hashes.into_iter().collect()))
        .collect()
}

fn restrictive_specification(members: &[&SnapshotMember]) -> Result<Value, Failure> {
    let candidates = members
        .iter()
        .filter(|member| member.object_type == "CONTRACT_LINE_ITEM")
        .copied()
        .collect::<Vec<_>>();
    let Some(member) = unique_target(&candidates, "CONTRACT_LINE_ITEM")? else {
        return Ok(json!({"specification": Value::Null}));
    };
    let payload = payload(member)?;
    let specification = payload
        .get("specification")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut output = Map::new();
    output.insert("id".to_owned(), Value::String(member.object_id.to_string()));
    copy_field(
        &specification,
        &mut output,
        "brandMentions",
        "brand_mentions",
    );
    copy_field(
        &specification,
        &mut output,
        "modelMentions",
        "model_mentions",
    );
    copy_field(
        &specification,
        &mut output,
        "equivalentAllowed",
        "equivalent_allowed",
    );
    copy_field(
        &specification,
        &mut output,
        "validBidderCount",
        "valid_bidder_count",
    );
    copy_field(
        &specification,
        &mut output,
        "justificationPresent",
        "justification_present",
    );
    Ok(json!({"specification": output}))
}

fn unique_target<'a>(
    candidates: &[&'a SnapshotMember],
    object_type: &str,
) -> Result<Option<&'a SnapshotMember>, Failure> {
    match candidates {
        [] => Ok(None),
        [candidate] => Ok(Some(*candidate)),
        _ => Err(materialization_invalid(&format!(
            "ambiguous {object_type} target"
        ))),
    }
}

fn payload(member: &SnapshotMember) -> Result<&Map<String, Value>, Failure> {
    member
        .canonical_payload
        .as_object()
        .ok_or_else(|| materialization_invalid("canonicalPayload"))
}

fn copy_field(source: &Map<String, Value>, target: &mut Map<String, Value>, from: &str, to: &str) {
    target.insert(
        to.to_owned(),
        source.get(from).cloned().unwrap_or(Value::Null),
    );
}

fn copy_krw_field(
    source: &Map<String, Value>,
    target: &mut Map<String, Value>,
    from: &str,
    to: &str,
) -> Result<(), Failure> {
    let value = canonical_krw_integer(source.get(from), from)?;
    target.insert(to.to_owned(), value);
    Ok(())
}

fn krw_config_value(configuration: &Value, key: &str) -> Result<Value, Failure> {
    canonical_krw_integer(configuration.get(key), key)
}

fn canonical_krw_integer(value: Option<&Value>, field: &str) -> Result<Value, Failure> {
    let Some(value) = value.filter(|value| !value.is_null()) else {
        return Ok(Value::Null);
    };
    let decimal = decimal_value(value).ok_or_else(|| materialization_invalid(field))?;
    if decimal < Decimal::ZERO || decimal.fract() != Decimal::ZERO {
        return Err(materialization_invalid(field));
    }
    Ok(Value::String(decimal.normalize().to_string()))
}

fn config_value(configuration: &Value, key: &str) -> Value {
    configuration.get(key).cloned().unwrap_or(Value::Null)
}

fn materialization_invalid(detail: &str) -> Failure {
    Failure::Terminal("RULE_INPUT_MATERIALIZATION_INVALID", detail.to_owned())
}

#[cfg(test)]
#[path = "analysis_rule_materializer_tests.rs"]
mod tests;
