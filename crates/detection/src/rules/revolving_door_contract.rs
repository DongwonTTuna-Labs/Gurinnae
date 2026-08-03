use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use time::{Date, Duration};

use crate::engine::{Evaluation, EvaluationError, blocked, finish};

const COOLING_BOUNDARY: &str = "DEPARTURE_EXCLUSIVE_COOLING_END_INCLUSIVE";
const OFFICIAL_ROLE_KIND: &str = "FORMER_OFFICIAL_ROLE";
const OFFICER_ROLE_KIND: &str = "MANAGEMENT_ROLE";

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let policy = match parse_policy(input) {
        Ok(policy) => policy,
        Err(code) => return blocked(code, input),
    };
    if let Err(code) = validate_source_coverage(input) {
        return blocked(code, input);
    }
    let former_roles = match parse_former_roles(input) {
        Ok(roles) => roles,
        Err(code) => return blocked(code, input),
    };
    let officer_roles = match parse_officer_roles(input) {
        Ok(roles) => roles,
        Err(code) => return blocked(code, input),
    };
    let contracts = match parse_contracts(input) {
        Ok(contracts) => contracts,
        Err(code) => return blocked(code, input),
    };
    let matches = find_matches(&policy, &former_roles, &officer_roles, &contracts);
    finish_result(input, &policy, &contracts, matches)
}

struct Policy {
    cooling_period_days: i64,
    cooling_period: Duration,
    procurement_methods: BTreeSet<String>,
}

struct FormerRole<'a> {
    relationship_id: &'a str,
    person_digest: &'a str,
    agency_id: &'a str,
    departed_on: Date,
}

struct OfficerRole<'a> {
    relationship_id: &'a str,
    person_digest: &'a str,
    supplier_id: &'a str,
    valid_from: Date,
    valid_to: Option<Date>,
}

struct Contract<'a> {
    id: &'a str,
    agency_id: &'a str,
    supplier_id: &'a str,
    signed_on: Date,
    procurement_method: &'a str,
}

struct Matches {
    contract_ids: BTreeSet<String>,
    person_digests: BTreeSet<String>,
    former_role_ids: BTreeSet<String>,
    officer_role_ids: BTreeSet<String>,
}

fn parse_policy(input: &Value) -> Result<Policy, &'static str> {
    let policy = object(input.get("policy"))?;
    let cooling_period_days = integer(policy, "cooling_period_days")?;
    if cooling_period_days <= 0 {
        return Err("POLICY_CONFIGURATION_INVALID");
    }
    let cooling_seconds = cooling_period_days
        .checked_mul(86_400)
        .ok_or("POLICY_CONFIGURATION_INVALID")?;
    if text(policy, "cooling_boundary")? != COOLING_BOUNDARY {
        return Err("POLICY_CONFIGURATION_INVALID");
    }
    let values = policy
        .get("procurement_method_allowlist")
        .and_then(Value::as_array)
        .ok_or("REQUIRED_FIELD_MISSING")?;
    let mut methods = BTreeSet::new();
    for value in values {
        let method = value.as_str().ok_or("POLICY_CONFIGURATION_INVALID")?;
        if !valid_policy_token(method) || !methods.insert(method.to_owned()) {
            return Err("POLICY_CONFIGURATION_INVALID");
        }
    }
    if methods.is_empty() {
        return Err("POLICY_CONFIGURATION_INVALID");
    }
    Ok(Policy {
        cooling_period_days,
        cooling_period: Duration::seconds(cooling_seconds),
        procurement_methods: methods,
    })
}

fn validate_source_coverage(input: &Value) -> Result<(), &'static str> {
    let coverage = object(input.get("source_coverage"))?;
    if !boolean(coverage, "official_reemployment_source_available")? {
        return Err("OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE");
    }
    if !boolean(coverage, "coverage_complete")? {
        return Err("OFFICIAL_REEMPLOYMENT_COVERAGE_INCOMPLETE");
    }
    Ok(())
}

fn parse_former_roles(input: &Value) -> Result<Vec<FormerRole<'_>>, &'static str> {
    let values = array(input, "former_official_roles")?;
    values
        .iter()
        .map(|value| {
            let row = object(Some(value))?;
            validate_relationship(row, OFFICIAL_ROLE_KIND, "PERSON", "AGENCY")?;
            let source_kind = text(row, "source_kind")?;
            if !matches!(
                source_kind,
                "PUBLIC_OFFICIAL_ETHICS_NOTICE" | "OFFICIAL_GAZETTE"
            ) {
                return Err("OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE");
            }
            Ok(FormerRole {
                relationship_id: nonempty_text(row, "relationship_id")?,
                person_digest: person_digest(row)?,
                agency_id: nonempty_text(row, "agency_id")?,
                departed_on: required_date(row, "departed_on")?,
            })
        })
        .collect()
}

fn parse_officer_roles(input: &Value) -> Result<Vec<OfficerRole<'_>>, &'static str> {
    let values = array(input, "supplier_officer_roles")?;
    values
        .iter()
        .map(|value| {
            let row = object(Some(value))?;
            validate_relationship(row, OFFICER_ROLE_KIND, "PERSON", "SUPPLIER")?;
            if text(row, "source_kind")? != "DART_EXECUTIVE_STATUS" {
                return Err("OFFICER_SOURCE_NOT_AUTHORITATIVE");
            }
            Ok(OfficerRole {
                relationship_id: nonempty_text(row, "relationship_id")?,
                person_digest: person_digest(row)?,
                supplier_id: nonempty_text(row, "supplier_id")?,
                valid_from: required_date(row, "valid_from")?,
                valid_to: optional_date(row, "valid_to")?,
            })
        })
        .collect()
}

fn parse_contracts(input: &Value) -> Result<Vec<Contract<'_>>, &'static str> {
    let values = array(input, "contracts")?;
    let mut ids = BTreeSet::new();
    values
        .iter()
        .map(|value| {
            let row = object(Some(value))?;
            let id = nonempty_text(row, "id")?;
            if !ids.insert(id) {
                return Err("DUPLICATE_CONTRACT_ID");
            }
            Ok(Contract {
                id,
                agency_id: nonempty_text(row, "agency_id")?,
                supplier_id: nonempty_text(row, "supplier_id")?,
                signed_on: required_date(row, "signed_on")?,
                procurement_method: nonempty_text(row, "procurement_method")?,
            })
        })
        .collect()
}

fn validate_relationship(
    row: &Map<String, Value>,
    relationship_kind: &str,
    subject_kind: &str,
    object_kind: &str,
) -> Result<(), &'static str> {
    if text(row, "relationship_kind")? != relationship_kind
        || text(row, "subject_kind")? != subject_kind
        || text(row, "object_kind")? != object_kind
    {
        return Err("RELATIONSHIP_SHAPE_INVALID");
    }
    if text(row, "validity_coverage_status")? != "COMPLETE" {
        return Err("TEMPORAL_COVERAGE_INCOMPLETE");
    }
    if text(row, "verification_status")? != "VERIFIED"
        || text(row, "public_use_status")? != "APPROVED"
        || !boolean(row, "independent_human_verification")?
    {
        return Err("RELATIONSHIP_REVIEW_INCOMPLETE");
    }
    nonempty_text(row, "evidence_id")?;
    nonempty_text(row, "source_locator")?;
    Ok(())
}

fn find_matches(
    policy: &Policy,
    former_roles: &[FormerRole<'_>],
    officer_roles: &[OfficerRole<'_>],
    contracts: &[Contract<'_>],
) -> Matches {
    let mut matches = Matches {
        contract_ids: BTreeSet::new(),
        person_digests: BTreeSet::new(),
        former_role_ids: BTreeSet::new(),
        officer_role_ids: BTreeSet::new(),
    };
    for contract in contracts {
        if !policy
            .procurement_methods
            .contains(contract.procurement_method)
        {
            continue;
        }
        for officer in officer_roles
            .iter()
            .filter(|role| officer_covers_contract(role, contract))
        {
            for former in former_roles
                .iter()
                .filter(|role| former_role_matches(policy, role, officer, contract))
            {
                matches.contract_ids.insert(contract.id.to_owned());
                matches
                    .person_digests
                    .insert(former.person_digest.to_owned());
                matches
                    .former_role_ids
                    .insert(former.relationship_id.to_owned());
                matches
                    .officer_role_ids
                    .insert(officer.relationship_id.to_owned());
            }
        }
    }
    matches
}

fn officer_covers_contract(role: &OfficerRole<'_>, contract: &Contract<'_>) -> bool {
    role.supplier_id == contract.supplier_id
        && role.valid_from <= contract.signed_on
        && role.valid_to.is_none_or(|date| contract.signed_on <= date)
}

fn former_role_matches(
    policy: &Policy,
    former: &FormerRole<'_>,
    officer: &OfficerRole<'_>,
    contract: &Contract<'_>,
) -> bool {
    let elapsed = contract.signed_on - former.departed_on;
    former.person_digest == officer.person_digest
        && former.agency_id == contract.agency_id
        && elapsed > Duration::ZERO
        && elapsed <= policy.cooling_period
}

fn finish_result(
    input: &Value,
    policy: &Policy,
    contracts: &[Contract<'_>],
    matches: Matches,
) -> Result<Value, EvaluationError> {
    let signal = !matches.contract_ids.is_empty();
    let included_ids = matches.contract_ids.iter().cloned().collect();
    let excluded_ids = contracts
        .iter()
        .filter(|contract| !matches.contract_ids.contains(contract.id))
        .map(|contract| contract.id.to_owned())
        .collect();
    let mut metrics = Map::new();
    metrics.insert(
        "cooling_period_days".to_owned(),
        policy.cooling_period_days.into(),
    );
    metrics.insert("cooling_boundary".to_owned(), COOLING_BOUNDARY.into());
    metrics.insert(
        "procurement_method_allowlist".to_owned(),
        json!(policy.procurement_methods),
    );
    metrics.insert(
        "matched_contract_count".to_owned(),
        (matches.contract_ids.len() as u64).into(),
    );
    metrics.insert(
        "matched_person_digests".to_owned(),
        json!(matches.person_digests),
    );
    metrics.insert("former_role_ids".to_owned(), json!(matches.former_role_ids));
    metrics.insert(
        "officer_role_ids".to_owned(),
        json!(matches.officer_role_ids),
    );
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            included_ids,
            excluded_ids,
            metrics,
        },
        input,
    )
}

fn object(value: Option<&Value>) -> Result<&Map<String, Value>, &'static str> {
    value
        .ok_or("REQUIRED_FIELD_MISSING")?
        .as_object()
        .ok_or("INVALID_FIELD_SHAPE")
}

fn array<'a>(input: &'a Value, key: &str) -> Result<&'a Vec<Value>, &'static str> {
    input
        .get(key)
        .ok_or("REQUIRED_FIELD_MISSING")?
        .as_array()
        .ok_or("INVALID_FIELD_SHAPE")
}
fn text<'a>(row: &'a Map<String, Value>, key: &str) -> Result<&'a str, &'static str> {
    row.get(key)
        .ok_or("REQUIRED_FIELD_MISSING")?
        .as_str()
        .ok_or("INVALID_FIELD_SHAPE")
}
fn nonempty_text<'a>(row: &'a Map<String, Value>, key: &str) -> Result<&'a str, &'static str> {
    let value = text(row, key)?;
    if value.is_empty() {
        return Err("INVALID_FIELD_SHAPE");
    }
    Ok(value)
}
fn integer(row: &Map<String, Value>, key: &str) -> Result<i64, &'static str> {
    row.get(key)
        .ok_or("REQUIRED_FIELD_MISSING")?
        .as_i64()
        .ok_or("INVALID_FIELD_SHAPE")
}
fn boolean(row: &Map<String, Value>, key: &str) -> Result<bool, &'static str> {
    row.get(key)
        .ok_or("REQUIRED_FIELD_MISSING")?
        .as_bool()
        .ok_or("INVALID_FIELD_SHAPE")
}

fn required_date(row: &Map<String, Value>, key: &str) -> Result<Date, &'static str> {
    parse_date(text(row, key)?)
}

fn optional_date(row: &Map<String, Value>, key: &str) -> Result<Option<Date>, &'static str> {
    match row.get(key) {
        Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_str()
            .ok_or("INVALID_FIELD_SHAPE")
            .and_then(parse_date)
            .map(Some),
        None => Err("REQUIRED_FIELD_MISSING"),
    }
}

fn parse_date(value: &str) -> Result<Date, &'static str> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| "TEMPORAL_COVERAGE_INCOMPLETE")?;
    Date::parse(value, &format).map_err(|_| "TEMPORAL_COVERAGE_INCOMPLETE")
}

fn person_digest(row: &Map<String, Value>) -> Result<&str, &'static str> {
    let digest = text(row, "person_identifier_digest")?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("PERSON_IDENTITY_AMBIGUOUS");
    }
    Ok(digest)
}

fn valid_policy_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}
