use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use time::{Date, Month};

use crate::engine::{Evaluation, EvaluationError, blocked, finish};

const POLICY_MISSING: &str = "POLICY_MISSING";
const POLICY_INVALID: &str = "POLICY_INVALID";
const SOURCE_UNAVAILABLE: &str = "STRUCTURED_BIDDER_SOURCE_UNAVAILABLE";
const SOURCE_INCOMPLETE: &str = "STRUCTURED_BIDDER_COVERAGE_INCOMPLETE";
const PARTICIPANT_INCOMPLETE: &str = "PARTICIPANT_RECORD_INCOMPLETE";
const PARTICIPANT_IDENTITY_INCOMPLETE: &str = "PARTICIPANT_IDENTITY_INCOMPLETE";
const RELATIONSHIP_COVERAGE_INCOMPLETE: &str = "RELATIONSHIP_COVERAGE_INCOMPLETE";
const RELATIONSHIP_PATH_INCOMPLETE: &str = "RELATIONSHIP_PATH_INCOMPLETE";
const RELATIONSHIP_KIND_UNKNOWN: &str = "RELATIONSHIP_KIND_UNKNOWN";
const RELATIONSHIP_IDENTITY_INCOMPLETE: &str = "RELATIONSHIP_IDENTITY_INCOMPLETE";
const RELATIONSHIP_PERIOD_INCOMPLETE: &str = "RELATIONSHIP_PERIOD_INCOMPLETE";

#[derive(Debug)]
struct RuleInput {
    procurement_id: String,
    valid_participants: BTreeSet<String>,
    maximum_relationship_hops: usize,
    active_edges: Vec<RelationshipEdge>,
    relationship_ids: BTreeSet<String>,
}

#[derive(Debug)]
struct RelationshipEdge {
    id: String,
    source: String,
    target: String,
}

#[derive(Debug)]
struct LinkedCompetitors {
    first: String,
    second: String,
    relationship_ids: Vec<String>,
}

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let parsed = match parse_input(input) {
        Ok(parsed) => parsed,
        Err(code) => return blocked(code, input),
    };
    let matched = first_linked_pair(&parsed);
    let metrics = metrics(&parsed, matched.as_ref());
    let universe = evidence_universe(&parsed);
    let included_ids = matched
        .as_ref()
        .map(|linked| {
            let mut ids = vec![
                parsed.procurement_id.clone(),
                linked.first.clone(),
                linked.second.clone(),
            ];
            ids.extend(linked.relationship_ids.iter().cloned());
            ids
        })
        .unwrap_or_default();
    let included_set = included_ids.iter().cloned().collect::<BTreeSet<_>>();
    let excluded_ids = universe
        .into_iter()
        .filter(|id| !included_set.contains(id))
        .collect();
    finish(
        Evaluation {
            outcome: if matched.is_some() {
                "SIGNAL"
            } else {
                "NO_SIGNAL"
            },
            blockers: Vec::new(),
            metrics,
            included_ids,
            excluded_ids,
        },
        input,
    )
}

fn parse_input(input: &Value) -> Result<RuleInput, &'static str> {
    let policy = object(input.get("policy"), POLICY_MISSING)?;
    let minimum_linked = usize_value(policy.get("minimum_linked_participants"), POLICY_MISSING)?;
    let maximum_hops = usize_value(policy.get("maximum_relationship_hops"), POLICY_MISSING)?;
    if minimum_linked != 2 || !(1..=2).contains(&maximum_hops) {
        return Err(POLICY_INVALID);
    }
    let procurement = object(input.get("procurement"), PARTICIPANT_INCOMPLETE)?;
    assert_structured_source(procurement)?;
    let procurement_id = text(procurement.get("id"), PARTICIPANT_INCOMPLETE)?.to_owned();
    let bid_opened_at = parse_date(text(
        procurement.get("bid_opened_at"),
        RELATIONSHIP_PERIOD_INCOMPLETE,
    )?)
    .ok_or(RELATIONSHIP_PERIOD_INCOMPLETE)?;
    let valid_participants = parse_participants(procurement)?;
    if !boolean(
        input.get("relationship_coverage_complete"),
        RELATIONSHIP_COVERAGE_INCOMPLETE,
    )? {
        return Err(RELATIONSHIP_COVERAGE_INCOMPLETE);
    }
    let relationships = array(input.get("relationships"), RELATIONSHIP_COVERAGE_INCOMPLETE)?;
    let (active_edges, relationship_ids) = parse_relationships(relationships, bid_opened_at)?;
    Ok(RuleInput {
        procurement_id,
        valid_participants,
        maximum_relationship_hops: maximum_hops,
        active_edges,
        relationship_ids,
    })
}

fn assert_structured_source(procurement: &Map<String, Value>) -> Result<(), &'static str> {
    let source = object(
        procurement.get("structured_participant_source"),
        SOURCE_UNAVAILABLE,
    )?;
    let authority = text(source.get("authority"), SOURCE_UNAVAILABLE)?;
    if authority.is_empty()
        || text(source.get("status"), SOURCE_UNAVAILABLE)? != "STRUCTURED_COMPLETE"
    {
        return Err(SOURCE_UNAVAILABLE);
    }
    if !boolean(source.get("coverage_complete"), SOURCE_INCOMPLETE)? {
        return Err(SOURCE_INCOMPLETE);
    }
    Ok(())
}

fn parse_participants(procurement: &Map<String, Value>) -> Result<BTreeSet<String>, &'static str> {
    let rows = array(procurement.get("participants"), PARTICIPANT_INCOMPLETE)?;
    let mut valid = BTreeSet::new();
    for row in rows {
        let participant = object(Some(row), PARTICIPANT_INCOMPLETE)?;
        let supplier_id = text(participant.get("supplier_id"), PARTICIPANT_INCOMPLETE)?;
        let status = text(
            participant.get("participation_status"),
            PARTICIPANT_INCOMPLETE,
        )?;
        let identity = text(participant.get("identity_status"), PARTICIPANT_INCOMPLETE)?;
        match status {
            "VALID" if identity != "VERIFIED" => {
                return Err(PARTICIPANT_IDENTITY_INCOMPLETE);
            }
            "VALID" => {
                valid.insert(supplier_id.to_owned());
            }
            "WITHDRAWN" | "DISQUALIFIED" | "INVALID" => {}
            _ => return Err(PARTICIPANT_INCOMPLETE),
        }
    }
    Ok(valid)
}

fn parse_relationships(
    rows: &[Value],
    bid_opened_at: Date,
) -> Result<(Vec<RelationshipEdge>, BTreeSet<String>), &'static str> {
    let mut active = Vec::new();
    let mut all_ids = BTreeSet::new();
    for row in rows {
        let edge = object(Some(row), RELATIONSHIP_PATH_INCOMPLETE)?;
        let id = text(edge.get("id"), RELATIONSHIP_PATH_INCOMPLETE)?.to_owned();
        if !all_ids.insert(id.clone()) {
            return Err(RELATIONSHIP_PATH_INCOMPLETE);
        }
        let kind = text(edge.get("kind"), RELATIONSHIP_PATH_INCOMPLETE)?;
        match kind {
            "OWNERSHIP" | "CONTROL" => {}
            "BENEFICIAL_OWNERSHIP"
            | "SHARED_BANK"
            | "SHARED_PHONE"
            | "SHARED_ADDRESS"
            | "MANAGEMENT_ROLE"
            | "BID_PARTICIPATION"
            | "SANCTION"
            | "FORMER_OFFICIAL_ROLE" => continue,
            _ => return Err(RELATIONSHIP_KIND_UNKNOWN),
        }
        let parsed = parse_candidate_edge(edge, id, bid_opened_at)?;
        if let Some(parsed) = parsed {
            active.push(parsed);
        }
    }
    active.sort_by(|left, right| left.id.cmp(&right.id));
    Ok((active, all_ids))
}

fn parse_candidate_edge(
    edge: &Map<String, Value>,
    id: String,
    bid_opened_at: Date,
) -> Result<Option<RelationshipEdge>, &'static str> {
    let source = text(edge.get("source_supplier_id"), RELATIONSHIP_PATH_INCOMPLETE)?;
    let target = text(edge.get("target_supplier_id"), RELATIONSHIP_PATH_INCOMPLETE)?;
    let verification = text(
        edge.get("verification_status"),
        RELATIONSHIP_PATH_INCOMPLETE,
    )?;
    let public_use = text(edge.get("public_use_status"), RELATIONSHIP_PATH_INCOMPLETE)?;
    let source_identity = text(
        edge.get("source_identity_status"),
        RELATIONSHIP_IDENTITY_INCOMPLETE,
    )?;
    let target_identity = text(
        edge.get("target_identity_status"),
        RELATIONSHIP_IDENTITY_INCOMPLETE,
    )?;
    if source_identity != "VERIFIED" || target_identity != "VERIFIED" {
        return Err(RELATIONSHIP_IDENTITY_INCOMPLETE);
    }
    let (valid_from, valid_to) = relationship_period(edge)?;
    if verification != "VERIFIED" || public_use != "APPROVED" {
        return Ok(None);
    }
    if source == target || bid_opened_at < valid_from || bid_opened_at > valid_to {
        return Ok(None);
    }
    Ok(Some(RelationshipEdge {
        id,
        source: source.to_owned(),
        target: target.to_owned(),
    }))
}

fn relationship_period(edge: &Map<String, Value>) -> Result<(Date, Date), &'static str> {
    if !boolean(
        edge.get("period_coverage_complete"),
        RELATIONSHIP_PERIOD_INCOMPLETE,
    )? {
        return Err(RELATIONSHIP_PERIOD_INCOMPLETE);
    }
    let valid_from = parse_date(text(
        edge.get("valid_from"),
        RELATIONSHIP_PERIOD_INCOMPLETE,
    )?)
    .ok_or(RELATIONSHIP_PERIOD_INCOMPLETE)?;
    let valid_to = parse_date(text(edge.get("valid_to"), RELATIONSHIP_PERIOD_INCOMPLETE)?)
        .ok_or(RELATIONSHIP_PERIOD_INCOMPLETE)?;
    if valid_from > valid_to {
        return Err(RELATIONSHIP_PERIOD_INCOMPLETE);
    }
    Ok((valid_from, valid_to))
}

fn first_linked_pair(input: &RuleInput) -> Option<LinkedCompetitors> {
    let participants = input.valid_participants.iter().collect::<Vec<_>>();
    for (index, first) in participants.iter().enumerate() {
        for second in participants.iter().skip(index + 1) {
            if let Some(relationship_ids) = path_between(
                first,
                second,
                &input.active_edges,
                input.maximum_relationship_hops,
            ) {
                return Some(LinkedCompetitors {
                    first: (*first).clone(),
                    second: (*second).clone(),
                    relationship_ids,
                });
            }
        }
    }
    None
}

fn path_between(
    first: &str,
    second: &str,
    edges: &[RelationshipEdge],
    maximum_hops: usize,
) -> Option<Vec<String>> {
    let mut candidates = Vec::new();
    for edge in edges {
        if edge_connects(edge, first, second) {
            candidates.push(vec![edge.id.clone()]);
        }
    }
    if maximum_hops >= 2 {
        for first_edge in edges {
            let Some(middle) = other_endpoint(first_edge, first) else {
                continue;
            };
            if middle == second {
                continue;
            }
            for second_edge in edges {
                if first_edge.id != second_edge.id && edge_connects(second_edge, middle, second) {
                    candidates.push(vec![first_edge.id.clone(), second_edge.id.clone()]);
                }
            }
        }
    }
    candidates.sort_by(|left, right| left.len().cmp(&right.len()).then(left.cmp(right)));
    candidates.into_iter().next()
}

fn edge_connects(edge: &RelationshipEdge, first: &str, second: &str) -> bool {
    (edge.source == first && edge.target == second)
        || (edge.source == second && edge.target == first)
}

fn other_endpoint<'a>(edge: &'a RelationshipEdge, endpoint: &str) -> Option<&'a str> {
    if edge.source == endpoint {
        Some(&edge.target)
    } else if edge.target == endpoint {
        Some(&edge.source)
    } else {
        None
    }
}

fn metrics(input: &RuleInput, matched: Option<&LinkedCompetitors>) -> Map<String, Value> {
    let mut metrics = Map::new();
    metrics.insert(
        "procurement_id".to_owned(),
        input.procurement_id.clone().into(),
    );
    metrics.insert(
        "valid_participant_count".to_owned(),
        (input.valid_participants.len() as u64).into(),
    );
    metrics.insert(
        "maximum_relationship_hops".to_owned(),
        (input.maximum_relationship_hops as u64).into(),
    );
    metrics.insert(
        "linked_participant_ids".to_owned(),
        matched
            .map(|linked| json!([linked.first.clone(), linked.second.clone()]))
            .unwrap_or_else(|| json!([])),
    );
    metrics.insert(
        "path_hops".to_owned(),
        matched
            .map(|linked| linked.relationship_ids.len() as u64)
            .unwrap_or_default()
            .into(),
    );
    metrics.insert(
        "relationship_ids".to_owned(),
        matched
            .map(|linked| json!(linked.relationship_ids.clone()))
            .unwrap_or_else(|| json!([])),
    );
    metrics
}

fn evidence_universe(input: &RuleInput) -> BTreeSet<String> {
    let mut ids = input.valid_participants.clone();
    ids.insert(input.procurement_id.clone());
    ids.extend(input.relationship_ids.iter().cloned());
    ids
}

fn object<'a>(
    value: Option<&'a Value>,
    blocker: &'static str,
) -> Result<&'a Map<String, Value>, &'static str> {
    value.and_then(Value::as_object).ok_or(blocker)
}

fn array<'a>(value: Option<&'a Value>, blocker: &'static str) -> Result<&'a [Value], &'static str> {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(blocker)
}

fn text<'a>(value: Option<&'a Value>, blocker: &'static str) -> Result<&'a str, &'static str> {
    value.and_then(Value::as_str).ok_or(blocker)
}

fn boolean(value: Option<&Value>, blocker: &'static str) -> Result<bool, &'static str> {
    value.and_then(Value::as_bool).ok_or(blocker)
}

fn usize_value(value: Option<&Value>, blocker: &'static str) -> Result<usize, &'static str> {
    value
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or(blocker)
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
