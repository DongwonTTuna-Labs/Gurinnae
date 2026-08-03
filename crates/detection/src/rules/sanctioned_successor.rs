use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};
use time::{Date, Month};

use crate::engine::{
    Evaluation, EvaluationError, blocked, bool_value, finish, integer, missing, string,
};

const CANONICAL_STRONG_SCHEMES: [&str; 3] = [
    "KOREAN_BUSINESS_NUMBER",
    "OPEN_DART_CORP_CODE",
    "KONEPS_PARTY_KEY",
];
const OFFICIAL_PERSON_SOURCES: [&str; 4] = [
    "DART_EXECUTIVE_STATUS",
    "ALIO_EXECUTIVE_STATUS",
    "OFFICIAL_GAZETTE",
    "PUBLIC_OFFICIAL_ETHICS_NOTICE",
];

#[derive(Clone, Copy)]
enum AnchorMode {
    StartInclusive,
    EndInclusive,
}

#[derive(Clone, Copy)]
enum LinkMode {
    StrongOrOfficer,
    StrongOnly,
    OfficerOnly,
}

struct Policy<'a> {
    maximum_new_entity_age_days: i64,
    post_sanction_award_window_days: i64,
    anchor_mode: AnchorMode,
    anchor_mode_text: &'a str,
    link_mode: LinkMode,
    link_mode_text: &'a str,
}

#[derive(Default)]
struct LinkEvidence {
    strong: BTreeSet<String>,
    officers: BTreeSet<String>,
    incomplete: bool,
}

#[derive(Default)]
struct EvaluationAggregate {
    included: BTreeSet<String>,
    matched_context_count: u64,
    matched_strong: BTreeSet<String>,
    matched_officers: BTreeSet<String>,
    candidate_count: u64,
    incomplete_link: bool,
}

struct PairMatch<'a> {
    sanction_id: &'a str,
    award_id: &'a str,
    sanctioned_supplier_id: &'a str,
    successor_id: &'a str,
    evidence: LinkEvidence,
}

enum PairDisposition<'a> {
    Ignore,
    TemporalIncomplete,
    LinkIncomplete,
    Match(PairMatch<'a>),
}

impl EvaluationAggregate {
    fn record_match(&mut self, matched: PairMatch<'_>) {
        self.matched_context_count += 1;
        self.included.extend([
            matched.sanction_id.to_owned(),
            matched.award_id.to_owned(),
            matched.sanctioned_supplier_id.to_owned(),
            matched.successor_id.to_owned(),
        ]);
        self.matched_strong.extend(matched.evidence.strong);
        self.matched_officers.extend(matched.evidence.officers);
    }

    fn finish(
        self,
        input: &Value,
        policy: &Policy<'_>,
        sanctions: &[Value],
        awards: &[Value],
    ) -> Result<Value, EvaluationError> {
        if self.matched_context_count == 0 && self.incomplete_link {
            return blocked("LINK_EVIDENCE_INCOMPLETE", input);
        }
        let all_evidence_ids = sanctions
            .iter()
            .chain(awards)
            .map(|record| string(&record["id"]).map(ToOwned::to_owned))
            .collect::<Result<BTreeSet<_>, _>>()?;
        let excluded_ids = all_evidence_ids
            .difference(&self.included)
            .cloned()
            .collect();
        let Value::Object(metrics) = json!({
            "candidate_context_count": self.candidate_count,
            "matched_context_count": self.matched_context_count,
            "shared_strong_identifier_count": self.matched_strong.len(),
            "shared_approved_officer_count": self.matched_officers.len(),
            "maximum_new_entity_age_days": policy.maximum_new_entity_age_days,
            "post_sanction_award_window_days": policy.post_sanction_award_window_days,
            "sanction_effective_date_semantics": policy.anchor_mode_text,
            "link_match_mode": policy.link_mode_text,
        }) else {
            return Err(EvaluationError::Serialization);
        };
        finish(
            Evaluation {
                outcome: if self.matched_context_count == 0 {
                    "NO_SIGNAL"
                } else {
                    "SIGNAL"
                },
                blockers: Vec::new(),
                metrics,
                included_ids: self.included.into_iter().collect(),
                excluded_ids,
            },
            input,
        )
    }
}

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    if missing(input, "policy") {
        return blocked("RULE_POLICY_INACTIVE", input);
    }
    let Some(policy) = policy(input)? else {
        return blocked("RULE_POLICY_INVALID", input);
    };
    if required_input_missing(input) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    if string(&input["sanction_source_status"])? != "READY" {
        return blocked("SANCTION_SOURCE_NOT_READY", input);
    }

    let sanctions = array(input, "sanctions")?;
    let suppliers = array(input, "suppliers")?;
    let awards = array(input, "awards")?;
    if sanctions.is_empty() || suppliers.len() < 2 || awards.is_empty() {
        return blocked("INSUFFICIENT_CONTEXT", input);
    }
    if base_records_missing(sanctions, suppliers, awards, policy.anchor_mode) {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }

    let Some(supplier_by_id) = suppliers_by_id(suppliers)? else {
        return blocked("ENTITY_BINDING_MISMATCH", input);
    };
    if context_binding_incomplete(sanctions, awards, &supplier_by_id)? {
        return blocked("ENTITY_BINDING_MISMATCH", input);
    }
    if temporal_coverage_incomplete(sanctions, suppliers)? {
        return blocked("TEMPORAL_COVERAGE_INCOMPLETE", input);
    }

    evaluate_contexts(input, &policy, sanctions, awards, &supplier_by_id)
}

fn evaluate_contexts(
    input: &Value,
    policy: &Policy<'_>,
    sanctions: &[Value],
    awards: &[Value],
    suppliers: &BTreeMap<&str, &Value>,
) -> Result<Value, EvaluationError> {
    let mut aggregate = EvaluationAggregate::default();
    for sanction in sanctions {
        for award in awards {
            if string(&award["supplier_id"])? != string(&sanction["supplier_id"])? {
                aggregate.candidate_count += 1;
            }
            match evaluate_pair(input, policy, sanction, award, suppliers)? {
                PairDisposition::Ignore => {}
                PairDisposition::TemporalIncomplete => {
                    return blocked("TEMPORAL_COVERAGE_INCOMPLETE", input);
                }
                PairDisposition::LinkIncomplete => aggregate.incomplete_link = true,
                PairDisposition::Match(matched) => aggregate.record_match(matched),
            }
        }
    }
    aggregate.finish(input, policy, sanctions, awards)
}

fn evaluate_pair<'a>(
    input: &Value,
    policy: &Policy<'_>,
    sanction: &'a Value,
    award: &'a Value,
    suppliers: &BTreeMap<&str, &Value>,
) -> Result<PairDisposition<'a>, EvaluationError> {
    let sanctioned_supplier_id = string(&sanction["supplier_id"])?;
    let successor_id = string(&award["supplier_id"])?;
    if successor_id == sanctioned_supplier_id {
        return Ok(PairDisposition::Ignore);
    }
    let anchor = sanction_anchor(sanction, policy.anchor_mode)?;
    let award_date = parse_date(string(&award["awarded_at"])?)?;
    let incorporated_at = parse_date(string(&suppliers[successor_id]["incorporated_at"])?)?;
    let age_days = days_between(incorporated_at, award_date);
    let post_sanction_days = days_between(anchor, award_date);
    if age_days < 0 {
        return Ok(PairDisposition::TemporalIncomplete);
    }
    if age_days > policy.maximum_new_entity_age_days
        || post_sanction_days < 0
        || post_sanction_days > policy.post_sanction_award_window_days
    {
        return Ok(PairDisposition::Ignore);
    }
    let evidence = link_evidence(
        input,
        policy.link_mode,
        sanctioned_supplier_id,
        successor_id,
        anchor,
        award_date,
    )?;
    if evidence.strong.is_empty() && evidence.officers.is_empty() {
        return Ok(if evidence.incomplete {
            PairDisposition::LinkIncomplete
        } else {
            PairDisposition::Ignore
        });
    }
    Ok(PairDisposition::Match(PairMatch {
        sanction_id: string(&sanction["id"])?,
        award_id: string(&award["id"])?,
        sanctioned_supplier_id,
        successor_id,
        evidence,
    }))
}

fn link_evidence(
    input: &Value,
    mode: LinkMode,
    sanctioned_supplier_id: &str,
    successor_id: &str,
    sanction_anchor: Date,
    award_date: Date,
) -> Result<LinkEvidence, EvaluationError> {
    let mut evidence = LinkEvidence::default();
    if matches!(mode, LinkMode::StrongOrOfficer | LinkMode::StrongOnly) {
        let coverage = bool_value(&input["strong_identifier_coverage_complete"])?;
        let (strong, facts_incomplete) = shared_strong_identifiers(
            array(input, "strong_identifier_facts")?,
            sanctioned_supplier_id,
            successor_id,
        );
        evidence.strong = strong;
        evidence.incomplete |= (facts_incomplete || !coverage) && evidence.strong.is_empty();
    }
    if matches!(mode, LinkMode::StrongOrOfficer | LinkMode::OfficerOnly) {
        let coverage = bool_value(&input["officer_role_coverage_complete"])?;
        let (officers, roles_incomplete) = shared_officers(
            array(input, "supplier_officer_roles")?,
            sanctioned_supplier_id,
            successor_id,
            sanction_anchor,
            award_date,
        )?;
        evidence.officers = officers;
        evidence.incomplete |= (roles_incomplete || !coverage) && evidence.officers.is_empty();
    }
    Ok(evidence)
}

fn shared_strong_identifiers(
    facts: &[Value],
    sanctioned_supplier_id: &str,
    successor_id: &str,
) -> (BTreeSet<String>, bool) {
    let first = eligible_strong_facts(facts, sanctioned_supplier_id);
    let second = eligible_strong_facts(facts, successor_id);
    (
        first.0.intersection(&second.0).cloned().collect(),
        first.1 || second.1,
    )
}

fn eligible_strong_facts(facts: &[Value], supplier_id: &str) -> (BTreeSet<String>, bool) {
    let mut result = BTreeSet::new();
    let mut incomplete = false;
    for fact in facts {
        let fields = (
            fact.get("supplier_id").and_then(Value::as_str),
            fact.get("scheme").and_then(Value::as_str),
            fact.get("value_hash").and_then(Value::as_str),
            fact.get("verification_status").and_then(Value::as_str),
            fact.get("proof_state").and_then(Value::as_str),
        );
        let (Some(fact_supplier), Some(scheme), Some(value_hash), Some(verification), Some(proof)) =
            fields
        else {
            incomplete = true;
            continue;
        };
        if fact_supplier != supplier_id {
            continue;
        }
        if CANONICAL_STRONG_SCHEMES.contains(&scheme)
            && verification == "VERIFIED"
            && proof == "PROVEN_V1"
        {
            if is_lower_sha256(value_hash) {
                result.insert(format!("{scheme}:{value_hash}"));
            } else {
                incomplete = true;
            }
        }
    }
    (result, incomplete)
}

fn shared_officers(
    roles: &[Value],
    sanctioned_supplier_id: &str,
    successor_id: &str,
    sanction_anchor: Date,
    award_date: Date,
) -> Result<(BTreeSet<String>, bool), EvaluationError> {
    let first = officer_roles(roles, sanctioned_supplier_id, sanction_anchor)?;
    let second = officer_roles(roles, successor_id, award_date)?;
    let shared = first.0.intersection(&second.0).cloned().collect();
    Ok((shared, first.1 || second.1))
}

fn officer_roles(
    roles: &[Value],
    supplier_id: &str,
    at: Date,
) -> Result<(BTreeSet<String>, bool), EvaluationError> {
    let mut digests = BTreeSet::new();
    let mut incomplete = false;
    for role in roles {
        let Some(role_supplier) = role.get("supplier_id").and_then(Value::as_str) else {
            incomplete = true;
            continue;
        };
        if role_supplier != supplier_id {
            continue;
        }
        let approved = match approved_officer_role(role) {
            Ok(value) => value,
            Err(_) => {
                incomplete = true;
                continue;
            }
        };
        if !approved {
            continue;
        }
        if string(&role["validity_coverage_status"])? != "COMPLETE" {
            incomplete = true;
            continue;
        }
        let Some(valid_from) = role.get("valid_from").and_then(Value::as_str) else {
            incomplete = true;
            continue;
        };
        let Ok(valid_from) = parse_date(valid_from) else {
            incomplete = true;
            continue;
        };
        let Some(valid_to_value) = role.get("valid_to") else {
            incomplete = true;
            continue;
        };
        let valid_to = if valid_to_value.is_null() {
            None
        } else if let Ok(value) = string(valid_to_value).and_then(parse_date) {
            Some(value)
        } else {
            incomplete = true;
            continue;
        };
        if valid_to.is_some_and(|end| end < valid_from) {
            incomplete = true;
            continue;
        }
        if valid_from <= at && valid_to.is_none_or(|end| at <= end) {
            digests.insert(string(&role["person_identifier_digest"])?.to_owned());
        }
    }
    Ok((digests, incomplete))
}

fn approved_officer_role(role: &Value) -> Result<bool, EvaluationError> {
    let digest = string(&role["person_identifier_digest"])?;
    let source_kind = string(&role["source_kind"])?;
    Ok(string(&role["relationship_kind"])? == "MANAGEMENT_ROLE"
        && string(&role["subject_kind"])? == "PERSON"
        && string(&role["object_kind"])? == "SUPPLIER"
        && string(&role["verification_status"])? == "VERIFIED"
        && string(&role["public_use_status"])? == "APPROVED"
        && bool_value(&role["independent_human_verification"])?
        && is_lower_sha256(digest)
        && OFFICIAL_PERSON_SOURCES.contains(&source_kind)
        && !string(&role["relationship_id"])?.trim().is_empty()
        && !string(&role["evidence_id"])?.trim().is_empty()
        && !string(&role["source_locator"])?.trim().is_empty())
}

fn policy(input: &Value) -> Result<Option<Policy<'_>>, EvaluationError> {
    let required = [
        "policy.maximum_new_entity_age_days",
        "policy.post_sanction_award_window_days",
        "policy.sanction_effective_date_semantics",
        "policy.link_match_mode",
    ];
    if required.iter().any(|path| missing(input, path)) {
        return Ok(None);
    }
    let maximum_age = integer(&input["policy"]["maximum_new_entity_age_days"])?;
    let post_window = integer(&input["policy"]["post_sanction_award_window_days"])?;
    let anchor_text = string(&input["policy"]["sanction_effective_date_semantics"])?;
    let link_text = string(&input["policy"]["link_match_mode"])?;
    let anchor_mode = match anchor_text {
        "START_DATE_INCLUSIVE" => AnchorMode::StartInclusive,
        "END_DATE_INCLUSIVE" => AnchorMode::EndInclusive,
        _ => return Ok(None),
    };
    let link_mode = match link_text {
        "STRONG_IDENTIFIER_OR_APPROVED_OFFICER" => LinkMode::StrongOrOfficer,
        "STRONG_IDENTIFIER_ONLY" => LinkMode::StrongOnly,
        "APPROVED_OFFICER_ONLY" => LinkMode::OfficerOnly,
        _ => return Ok(None),
    };
    if maximum_age < 0 || post_window < 0 {
        return Ok(None);
    }
    Ok(Some(Policy {
        maximum_new_entity_age_days: maximum_age,
        post_sanction_award_window_days: post_window,
        anchor_mode,
        anchor_mode_text: anchor_text,
        link_mode,
        link_mode_text: link_text,
    }))
}

fn required_input_missing(input: &Value) -> bool {
    [
        "sanction_source_status",
        "sanctions",
        "suppliers",
        "awards",
        "strong_identifier_facts",
        "supplier_officer_roles",
        "strong_identifier_coverage_complete",
        "officer_role_coverage_complete",
    ]
    .iter()
    .any(|path| missing(input, path))
}

fn base_records_missing(
    sanctions: &[Value],
    suppliers: &[Value],
    awards: &[Value],
    anchor_mode: AnchorMode,
) -> bool {
    sanctions.iter().any(|record| {
        ["id", "supplier_id", "effective_from"]
            .iter()
            .any(|field| record.get(*field).is_none_or(Value::is_null))
            || matches!(anchor_mode, AnchorMode::EndInclusive)
                && record.get("effective_to").is_none_or(Value::is_null)
    }) || suppliers.iter().any(|record| {
        ["id", "incorporated_at"]
            .iter()
            .any(|field| record.get(*field).is_none_or(Value::is_null))
    }) || awards.iter().any(|record| {
        ["id", "supplier_id", "awarded_at"]
            .iter()
            .any(|field| record.get(*field).is_none_or(Value::is_null))
    })
}

fn suppliers_by_id(suppliers: &[Value]) -> Result<Option<BTreeMap<&str, &Value>>, EvaluationError> {
    let mut result = BTreeMap::new();
    for supplier in suppliers {
        let id = string(&supplier["id"])?;
        if result.insert(id, supplier).is_some() {
            return Ok(None);
        }
    }
    Ok(Some(result))
}

fn context_binding_incomplete(
    sanctions: &[Value],
    awards: &[Value],
    suppliers: &BTreeMap<&str, &Value>,
) -> Result<bool, EvaluationError> {
    for record in sanctions.iter().chain(awards) {
        if !suppliers.contains_key(string(&record["supplier_id"])?) {
            return Ok(true);
        }
    }
    Ok(false)
}

fn temporal_coverage_incomplete(
    sanctions: &[Value],
    suppliers: &[Value],
) -> Result<bool, EvaluationError> {
    for sanction in sanctions {
        let start = parse_date(string(&sanction["effective_from"])?)?;
        if let Some(end) = sanction
            .get("effective_to")
            .filter(|value| !value.is_null())
            && parse_date(string(end)?)? < start
        {
            return Ok(true);
        }
    }
    for supplier in suppliers {
        parse_date(string(&supplier["incorporated_at"])?)?;
    }
    Ok(false)
}

fn sanction_anchor(sanction: &Value, mode: AnchorMode) -> Result<Date, EvaluationError> {
    match mode {
        AnchorMode::StartInclusive => parse_date(string(&sanction["effective_from"])?),
        AnchorMode::EndInclusive => parse_date(string(&sanction["effective_to"])?),
    }
}

fn array<'a>(input: &'a Value, field: &str) -> Result<&'a [Value], EvaluationError> {
    input[field]
        .as_array()
        .map(Vec::as_slice)
        .ok_or(EvaluationError::InvalidScalar)
}

fn days_between(start: Date, end: Date) -> i64 {
    i64::from(end.to_julian_day() - start.to_julian_day())
}

fn parse_date(value: &str) -> Result<Date, EvaluationError> {
    let parts = value.split('-').collect::<Vec<_>>();
    if parts.len() != 3 {
        return Err(EvaluationError::InvalidScalar);
    }
    let year = parts[0]
        .parse()
        .map_err(|_| EvaluationError::InvalidScalar)?;
    let month = Month::try_from(
        parts[1]
            .parse::<u8>()
            .map_err(|_| EvaluationError::InvalidScalar)?,
    )
    .map_err(|_| EvaluationError::InvalidScalar)?;
    let day = parts[2]
        .parse()
        .map_err(|_| EvaluationError::InvalidScalar)?;
    Date::from_calendar_date(year, month, day).map_err(|_| EvaluationError::InvalidScalar)
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
