use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{Evaluation, EvaluationError, blocked, finish, missing};

const REQUIRED_TOP_LEVEL: [&str; 9] = [
    "policy.minimum_distinct_suppliers",
    "source_coverage.dart_officer_assignments_complete",
    "source_coverage.award_records_complete",
    "source_coverage.relationship_periods_complete",
    "source_coverage.relationships_verified",
    "source_coverage.public_use_approved",
    "source_coverage.independent_human_verification_complete",
    "awards",
    "officer_assignments",
];

#[derive(Clone)]
struct Award {
    id: String,
    agency_id: String,
    supplier_id: String,
    awarded_on: Date,
}

struct OfficerAssignment {
    person_identifier_digest: String,
    supplier_id: String,
    valid_from: Date,
    valid_to: Date,
}

struct RuleInput {
    minimum_distinct_suppliers: usize,
    awards: Vec<Award>,
    assignments: Vec<OfficerAssignment>,
}

#[derive(Default)]
struct Candidate {
    supplier_ids: BTreeSet<String>,
    award_ids: BTreeSet<String>,
}

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if REQUIRED_TOP_LEVEL.iter().any(|path| missing(input, path)) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    let validated = match validate(input)? {
        Ok(validated) => validated,
        Err(code) => return blocked(code, input),
    };
    let candidates = build_candidates(&validated);
    let best = strongest_candidate(&candidates);
    let signal = best
        .map(|(_, candidate)| candidate.supplier_ids.len() >= validated.minimum_distinct_suppliers)
        .unwrap_or(false);
    let included_ids = if signal {
        best.map(|(_, candidate)| candidate.award_ids.iter().cloned().collect())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let included_set: BTreeSet<_> = included_ids.iter().cloned().collect();
    let excluded_ids = validated
        .awards
        .iter()
        .filter(|award| !included_set.contains(&award.id))
        .map(|award| award.id.clone())
        .collect();
    let mut metrics = Map::new();
    metrics.insert(
        "minimum_distinct_suppliers".to_owned(),
        (validated.minimum_distinct_suppliers as u64).into(),
    );
    metrics.insert(
        "matched_distinct_supplier_count".to_owned(),
        best.map_or(0, |(_, candidate)| candidate.supplier_ids.len() as u64)
            .into(),
    );
    metrics.insert(
        "matched_award_count".to_owned(),
        best.map_or(0, |(_, candidate)| candidate.award_ids.len() as u64)
            .into(),
    );
    if signal && let Some(((agency_id, person_digest), _)) = best {
        metrics.insert("agency_id".to_owned(), agency_id.clone().into());
        metrics.insert(
            "person_identifier_digest".to_owned(),
            person_digest.clone().into(),
        );
    }
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            metrics,
            included_ids,
            excluded_ids,
        },
        input,
    )
}

fn validate(input: &Value) -> Result<Result<RuleInput, &'static str>, EvaluationError> {
    let minimum = input["policy"]["minimum_distinct_suppliers"]
        .as_u64()
        .and_then(|value| usize::try_from(value).ok());
    let Some(minimum_distinct_suppliers) = minimum.filter(|value| *value >= 2) else {
        return Ok(Err("INVALID_POLICY_THRESHOLD"));
    };
    if let Some(blocker) = validate_source_coverage(input)? {
        return Ok(Err(blocker));
    }
    let Some(awards) = input["awards"].as_array() else {
        return Err(EvaluationError::InvalidScalar);
    };
    let Some(assignments) = input["officer_assignments"].as_array() else {
        return Err(EvaluationError::InvalidScalar);
    };
    if awards.is_empty() || assignments.is_empty() {
        return Ok(Err("INSUFFICIENT_CONTEXT"));
    }
    let awards = match parse_awards(awards)? {
        Ok(awards) => awards,
        Err(code) => return Ok(Err(code)),
    };
    let assignments = match parse_assignments(assignments)? {
        Ok(assignments) => assignments,
        Err(code) => return Ok(Err(code)),
    };
    Ok(Ok(RuleInput {
        minimum_distinct_suppliers,
        awards,
        assignments,
    }))
}

fn validate_source_coverage(input: &Value) -> Result<Option<&'static str>, EvaluationError> {
    let coverage = &input["source_coverage"];
    let source_fields = [
        "dart_officer_assignments_complete",
        "award_records_complete",
        "relationship_periods_complete",
    ];
    for field in source_fields {
        match coverage[field].as_bool() {
            Some(true) => {}
            Some(false) => return Ok(Some("SOURCE_COVERAGE_INCOMPLETE")),
            None => return Err(EvaluationError::InvalidScalar),
        }
    }
    let graph_fields = [
        "relationships_verified",
        "public_use_approved",
        "independent_human_verification_complete",
    ];
    for field in graph_fields {
        match coverage[field].as_bool() {
            Some(true) => {}
            Some(false) => return Ok(Some("RELATIONSHIP_GRAPH_NOT_APPROVED")),
            None => return Err(EvaluationError::InvalidScalar),
        }
    }
    Ok(None)
}

fn parse_awards(values: &[Value]) -> Result<Result<Vec<Award>, &'static str>, EvaluationError> {
    let mut seen = BTreeSet::new();
    let mut awards = Vec::with_capacity(values.len());
    for value in values {
        let Some(object) = value.as_object() else {
            return Err(EvaluationError::InvalidScalar);
        };
        if ["id", "agency_id", "supplier_id", "awarded_on"]
            .iter()
            .any(|field| object.get(*field).is_none_or(Value::is_null))
        {
            return Ok(Err("REQUIRED_FIELD_MISSING"));
        }
        let Some(id) = non_empty_string(&object["id"]) else {
            return Err(EvaluationError::InvalidScalar);
        };
        if !seen.insert(id.to_owned()) {
            return Ok(Err("DUPLICATE_RECORD_ID"));
        }
        let Some(awarded_on) = object["awarded_on"].as_str().and_then(parse_date) else {
            return Ok(Err("DATE_INVALID"));
        };
        awards.push(Award {
            id: id.to_owned(),
            agency_id: required_string(object, "agency_id")?.to_owned(),
            supplier_id: required_string(object, "supplier_id")?.to_owned(),
            awarded_on,
        });
    }
    Ok(Ok(awards))
}

fn parse_assignments(
    values: &[Value],
) -> Result<Result<Vec<OfficerAssignment>, &'static str>, EvaluationError> {
    let mut seen = BTreeSet::new();
    let mut assignments = Vec::with_capacity(values.len());
    for value in values {
        let Some(object) = value.as_object() else {
            return Err(EvaluationError::InvalidScalar);
        };
        let required = [
            "id",
            "person_identifier_digest",
            "supplier_id",
            "valid_from",
            "valid_to",
        ];
        if required
            .iter()
            .any(|field| object.get(*field).is_none_or(Value::is_null))
        {
            return Ok(Err("REQUIRED_FIELD_MISSING"));
        }
        let id = required_string(object, "id")?;
        if !seen.insert(id.to_owned()) {
            return Ok(Err("DUPLICATE_RECORD_ID"));
        }
        let digest = required_string(object, "person_identifier_digest")?;
        if !is_sha256(digest) {
            return Ok(Err("PERSON_IDENTITY_DIGEST_INVALID"));
        }
        let Some(valid_from) = object["valid_from"].as_str().and_then(parse_date) else {
            return Ok(Err("DATE_INVALID"));
        };
        let Some(valid_to) = object["valid_to"].as_str().and_then(parse_date) else {
            return Ok(Err("DATE_INVALID"));
        };
        if valid_from > valid_to {
            return Ok(Err("VALIDITY_INTERVAL_INVALID"));
        }
        assignments.push(OfficerAssignment {
            person_identifier_digest: digest.to_owned(),
            supplier_id: required_string(object, "supplier_id")?.to_owned(),
            valid_from,
            valid_to,
        });
    }
    Ok(Ok(assignments))
}

fn build_candidates(input: &RuleInput) -> BTreeMap<(String, String), Candidate> {
    let mut candidates = BTreeMap::new();
    for award in &input.awards {
        for assignment in &input.assignments {
            if award.supplier_id == assignment.supplier_id
                && award.awarded_on >= assignment.valid_from
                && award.awarded_on <= assignment.valid_to
            {
                let candidate = candidates
                    .entry((
                        award.agency_id.clone(),
                        assignment.person_identifier_digest.clone(),
                    ))
                    .or_insert_with(Candidate::default);
                candidate.supplier_ids.insert(award.supplier_id.clone());
                candidate.award_ids.insert(award.id.clone());
            }
        }
    }
    candidates
}

fn strongest_candidate(
    candidates: &BTreeMap<(String, String), Candidate>,
) -> Option<(&(String, String), &Candidate)> {
    let mut best = None;
    for candidate in candidates {
        if best.is_none_or(|(_, current): (&(String, String), &Candidate)| {
            candidate.1.supplier_ids.len() > current.supplier_ids.len()
        }) {
            best = Some(candidate);
        }
    }
    best
}

fn required_string<'a>(
    object: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a str, EvaluationError> {
    non_empty_string(&object[field]).ok_or(EvaluationError::InvalidScalar)
}

fn non_empty_string(value: &Value) -> Option<&str> {
    value.as_str().filter(|text| !text.is_empty())
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn parse_date(value: &str) -> Option<Date> {
    let mut parts = value.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = Month::try_from(parts.next()?.parse::<u8>().ok()?).ok()?;
    let day = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Date::from_calendar_date(year, month, day).ok()
}
