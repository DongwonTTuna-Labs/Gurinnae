use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::{Failure, MaterializedRuleInput, canonical_bytes, materialization_invalid, sha256};

const CONFLICT_RULES: [&str; 5] = [
    "OFFICER_OVERLAP_AWARD",
    "OWNERSHIP_LINKED_COMPETITORS",
    "BID_ROTATION",
    "REVOLVING_DOOR_CONTRACT",
    "SANCTIONED_SUCCESSOR",
];

pub(in crate::runner) fn is_conflict_rule(rule_id: &str) -> bool {
    CONFLICT_RULES.contains(&rule_id)
}

pub(in crate::runner) fn materialize_conflict_rule_input(
    rule_id: &str,
    configuration: &Value,
    frozen: &Value,
) -> Result<MaterializedRuleInput, Failure> {
    let coverage_state = FrozenCoverageState::read(frozen)?;
    let value = match rule_id {
        "OFFICER_OVERLAP_AWARD" => officer_overlap_award(configuration, frozen, coverage_state)?,
        "OWNERSHIP_LINKED_COMPETITORS" => {
            ownership_linked_competitors(configuration, frozen, coverage_state)?
        }
        "BID_ROTATION" => bid_rotation(configuration, frozen, coverage_state)?,
        "REVOLVING_DOOR_CONTRACT" => {
            revolving_door_contract(configuration, frozen, coverage_state)?
        }
        "SANCTIONED_SUCCESSOR" => sanctioned_successor(configuration, frozen, coverage_state)?,
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

#[derive(Clone, Copy, PartialEq, Eq)]
enum FrozenCoverageState {
    Complete,
    Partial,
    Blocked,
}

impl FrozenCoverageState {
    fn read(frozen: &Value) -> Result<Self, Failure> {
        match frozen.get("coverage_status").and_then(Value::as_str) {
            Some("COMPLETE") => Ok(Self::Complete),
            Some("PARTIAL") => Ok(Self::Partial),
            Some("BLOCKED") => Ok(Self::Blocked),
            _ => Err(materialization_invalid("coverage_status")),
        }
    }

    fn authority_available(self) -> bool {
        self != Self::Blocked
    }

    fn inputs_complete(self) -> bool {
        self == Self::Complete
    }
}

fn officer_overlap_award(
    configuration: &Value,
    frozen: &Value,
    coverage_state: FrozenCoverageState,
) -> Result<Value, Failure> {
    let mut input = Map::new();
    insert_policy(&mut input, configuration, &["minimum_distinct_suppliers"]);
    if !coverage_state.authority_available() {
        input.insert(
            "source_coverage".to_owned(),
            json!({
                "dart_officer_assignments_complete": false,
                "award_records_complete": false,
                "relationship_periods_complete": false,
                "relationships_verified": false,
                "public_use_approved": false,
                "independent_human_verification_complete": false,
            }),
        );
        input.insert("awards".to_owned(), json!([]));
        input.insert("officer_assignments".to_owned(), json!([]));
        return Ok(Value::Object(input));
    }
    let (awards, award_rows_complete) = officer_awards(frozen)?;
    let relations = frozen_array(frozen, "typed_relationship_assertions")?;
    let (assignments, role_rows_complete, periods_complete) = officer_assignments(relations)?;
    let source_complete = coverage(frozen, "typed_relationships_complete")?;
    let graph_complete = coverage_state.inputs_complete() && source_complete && role_rows_complete;
    input.insert(
        "source_coverage".to_owned(),
        json!({
            "dart_officer_assignments_complete": coverage_state.inputs_complete()
                && source_complete && role_rows_complete,
            "award_records_complete": coverage_state.inputs_complete()
                && coverage(frozen, "procurement_awards_complete")?
                && award_rows_complete,
            "relationship_periods_complete": coverage_state.inputs_complete()
                && source_complete && periods_complete,
            "relationships_verified": graph_complete,
            "public_use_approved": graph_complete,
            "independent_human_verification_complete": graph_complete,
        }),
    );
    input.insert("awards".to_owned(), Value::Array(awards));
    input.insert("officer_assignments".to_owned(), Value::Array(assignments));
    Ok(Value::Object(input))
}

fn ownership_linked_competitors(
    configuration: &Value,
    frozen: &Value,
    coverage_state: FrozenCoverageState,
) -> Result<Value, Failure> {
    let authority_available = coverage_state.authority_available();
    let participant_rows_complete =
        authority_available && coverage(frozen, "bidder_participations_complete")?;
    let notices = frozen_array(frozen, "procurement_notices")?;
    let notice = if participant_rows_complete {
        exact_row(notices, "procurement notice")?
    } else {
        None
    };
    let procurement = ownership_procurement(
        frozen,
        notice,
        authority_available,
        participant_rows_complete,
    )?;
    let relationships = if authority_available {
        ownership_relationships(frozen)?
    } else {
        Vec::new()
    };
    let mut input = Map::new();
    insert_policy(
        &mut input,
        configuration,
        &["minimum_linked_participants", "maximum_relationship_hops"],
    );
    input.insert("procurement".to_owned(), procurement);
    input.insert(
        "relationship_coverage_complete".to_owned(),
        Value::Bool(authority_available && coverage(frozen, "typed_relationships_complete")?),
    );
    input.insert("relationships".to_owned(), Value::Array(relationships));
    Ok(Value::Object(input))
}

fn bid_rotation(
    configuration: &Value,
    frozen: &Value,
    coverage_state: FrozenCoverageState,
) -> Result<Value, Failure> {
    let authority_available = coverage_state.authority_available();
    let mut input = Map::new();
    insert_policy(
        &mut input,
        configuration,
        &[
            "minimum_notice_count",
            "window_days",
            "minimum_bidders_per_notice",
            "minimum_distinct_winners",
            "cluster_metric",
            "cluster_tolerance_bps",
            "currency",
            "tie_handling",
        ],
    );
    input.insert(
        "participant_source".to_owned(),
        json!({
            "authority": coverage_value(frozen, "bidder_participation_authority")?,
            "status": if authority_available {"STRUCTURED_COMPLETE"} else {"UNAVAILABLE"},
        }),
    );
    input.insert(
        "observation_period_complete".to_owned(),
        Value::Bool(
            coverage_state.inputs_complete() && coverage(frozen, "procurement_notices_complete")?,
        ),
    );
    let notices = if authority_available {
        bid_rotation_notices(frozen)?
    } else {
        Vec::new()
    };
    input.insert("notices".to_owned(), Value::Array(notices));
    Ok(Value::Object(input))
}

fn revolving_door_contract(
    configuration: &Value,
    frozen: &Value,
    coverage_state: FrozenCoverageState,
) -> Result<Value, Failure> {
    let typed_complete = coverage(frozen, "typed_relationships_complete")?;
    let source_available = coverage_state.authority_available();
    let relations: &[Value] = if source_available {
        frozen_array(frozen, "typed_relationship_assertions")?.as_slice()
    } else {
        &[]
    };
    let mut input = Map::new();
    insert_policy(
        &mut input,
        configuration,
        &[
            "cooling_period_days",
            "procurement_method_allowlist",
            "cooling_boundary",
        ],
    );
    input.insert(
        "source_coverage".to_owned(),
        json!({
            "official_reemployment_source_available": source_available,
            "coverage_complete": coverage_state.inputs_complete() && typed_complete,
        }),
    );
    input.insert(
        "former_official_roles".to_owned(),
        Value::Array(former_official_roles(relations)?),
    );
    input.insert(
        "supplier_officer_roles".to_owned(),
        Value::Array(supplier_officer_roles(relations)?),
    );
    input.insert(
        "contracts".to_owned(),
        Value::Array(if source_available {
            revolving_contracts(frozen)?
        } else {
            Vec::new()
        }),
    );
    Ok(Value::Object(input))
}

fn sanctioned_successor(
    configuration: &Value,
    frozen: &Value,
    coverage_state: FrozenCoverageState,
) -> Result<Value, Failure> {
    let authority_available = coverage_state.authority_available();
    let sanctions = if authority_available {
        sanctioned_rows(frozen)?
    } else {
        Vec::new()
    };
    let mut input = Map::new();
    insert_policy(
        &mut input,
        configuration,
        &[
            "maximum_new_entity_age_days",
            "post_sanction_award_window_days",
            "sanction_effective_date_semantics",
            "link_match_mode",
        ],
    );
    input.insert(
        "sanction_source_status".to_owned(),
        Value::String(
            if authority_available {
                "READY"
            } else {
                "DISABLED"
            }
            .to_owned(),
        ),
    );
    input.insert("sanctions".to_owned(), Value::Array(sanctions));
    input.insert(
        "suppliers".to_owned(),
        Value::Array(if authority_available {
            sanctioned_suppliers(frozen)?
        } else {
            Vec::new()
        }),
    );
    input.insert(
        "awards".to_owned(),
        Value::Array(if authority_available {
            sanctioned_awards(frozen)?
        } else {
            Vec::new()
        }),
    );
    input.insert(
        "strong_identifier_facts".to_owned(),
        Value::Array(if authority_available {
            strong_identifier_facts(frozen)?
        } else {
            Vec::new()
        }),
    );
    input.insert(
        "supplier_officer_roles".to_owned(),
        Value::Array(if authority_available {
            supplier_officer_roles(frozen_array(frozen, "typed_relationship_assertions")?)?
        } else {
            Vec::new()
        }),
    );
    input.insert(
        "strong_identifier_coverage_complete".to_owned(),
        Value::Bool(authority_available && coverage(frozen, "strong_identifier_facts_complete")?),
    );
    input.insert(
        "officer_role_coverage_complete".to_owned(),
        Value::Bool(authority_available && coverage(frozen, "typed_relationships_complete")?),
    );
    Ok(Value::Object(input))
}

fn insert_policy(target: &mut Map<String, Value>, configuration: &Value, keys: &[&str]) {
    let Some(policy) = configuration.get("policy").and_then(Value::as_object) else {
        return;
    };
    let mut projected = Map::new();
    for key in keys {
        if let Some(value) = policy.get(*key) {
            let value = if *key == "cluster_tolerance_bps" {
                decimal_as_string(value)
            } else {
                value.clone()
            };
            projected.insert((*key).to_owned(), value);
        }
    }
    target.insert("policy".to_owned(), Value::Object(projected));
}

fn officer_awards(frozen: &Value) -> Result<(Vec<Value>, bool), Failure> {
    let mut complete = true;
    let mut output = Vec::new();
    for row in frozen_array(frozen, "procurement_awards")? {
        let row = object(row, "procurement_awards")?;
        let suppliers = row.get("supplier_ids").and_then(Value::as_array);
        let Some(supplier) = suppliers.and_then(|values| exact_value(values)) else {
            complete = false;
            continue;
        };
        complete &= required_values(row, &["id", "agency_id", "awarded_on"]);
        output.push(json!({
            "id": field(row,"id"),
            "agency_id": field(row,"agency_id"),
            "supplier_id": supplier,
            "awarded_on": field(row,"awarded_on"),
        }));
    }
    Ok((output, complete))
}

fn officer_assignments(rows: &[Value]) -> Result<(Vec<Value>, bool, bool), Failure> {
    let mut complete = true;
    let mut periods_complete = true;
    let mut output = Vec::new();
    for row in rows {
        let row = object(row, "typed_relationship_assertions")?;
        if field_text(row, "relationship_kind") != Some("MANAGEMENT_ROLE")
            || field_text(row, "subject_kind") != Some("PERSON")
            || field_text(row, "object_kind") != Some("SUPPLIER")
            || field_text(row, "source_kind") != Some("DART_EXECUTIVE_STATUS")
        {
            continue;
        }
        complete &= approved_relationship(row);
        periods_complete &= field_text(row, "validity_coverage_status") == Some("COMPLETE")
            && required_values(row, &["valid_from", "valid_to"]);
        output.push(json!({
            "id": field(row,"relationship_id"),
            "person_identifier_digest": field(row,"person_identifier_digest"),
            "supplier_id": field(row,"object_entity_id"),
            "valid_from": field(row,"valid_from"),
            "valid_to": field(row,"valid_to"),
        }));
    }
    Ok((output, complete, periods_complete))
}

fn ownership_procurement(
    frozen: &Value,
    notice: Option<&Value>,
    authority_available: bool,
    coverage_complete: bool,
) -> Result<Value, Failure> {
    let notice = notice
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let notice_id = notice.get("id").cloned().unwrap_or(Value::Null);
    let participants = if coverage_complete {
        participant_rows(frozen, &notice_id, ParticipantShape::Ownership)?.rows
    } else {
        Vec::new()
    };
    Ok(json!({
        "id": notice_id,
        "bid_opened_at": field(&notice,"bid_opened_at"),
        "structured_participant_source": {
            "authority": coverage_value(frozen,"bidder_participation_authority")?,
            "status": if authority_available {"STRUCTURED_COMPLETE"} else {"UNAVAILABLE"},
            "coverage_complete": coverage_complete,
        },
        "participants": participants,
    }))
}

fn ownership_relationships(frozen: &Value) -> Result<Vec<Value>, Failure> {
    let identity_statuses = supplier_identity_statuses(frozen)?;
    let mut output = Vec::new();
    for row in frozen_array(frozen, "typed_relationship_assertions")? {
        let row = object(row, "typed_relationship_assertions")?;
        if !matches!(
            field_text(row, "relationship_kind"),
            Some("OWNERSHIP" | "CONTROL")
        ) || field_text(row, "subject_kind") != Some("SUPPLIER")
            || field_text(row, "object_kind") != Some("SUPPLIER")
        {
            continue;
        }
        let source_supplier_id = field_text(row, "subject_entity_id");
        let target_supplier_id = field_text(row, "object_entity_id");
        output.push(json!({
            "id": field(row,"relationship_id"),
            "kind": field(row,"relationship_kind"),
            "source_supplier_id": field(row,"subject_entity_id"),
            "target_supplier_id": field(row,"object_entity_id"),
            "verification_status": field(row,"verification_status"),
            "public_use_status": field(row,"public_use_status"),
            "source_identity_status": source_supplier_id
                .and_then(|supplier_id| identity_statuses.get(supplier_id))
                .cloned()
                .unwrap_or(Value::Null),
            "target_identity_status": target_supplier_id
                .and_then(|supplier_id| identity_statuses.get(supplier_id))
                .cloned()
                .unwrap_or(Value::Null),
            "period_coverage_complete": field_text(row,"validity_coverage_status") == Some("COMPLETE"),
            "valid_from": field(row,"valid_from"),
            "valid_to": field(row,"valid_to"),
        }));
    }
    Ok(output)
}

fn bid_rotation_notices(frozen: &Value) -> Result<Vec<Value>, Failure> {
    let mut output = Vec::new();
    for notice in frozen_array(frozen, "procurement_notices")? {
        let notice = object(notice, "procurement_notices")?;
        let notice_id = field(notice, "id");
        let participants = participant_rows(frozen, &notice_id, ParticipantShape::Bid)?;
        let winner = award_winner_for_notice(frozen, &notice_id)?;
        let participant_complete =
            coverage(frozen, "bidder_participations_complete")? && participants.coverage_complete;
        let price_complete = participant_complete
            && participants.rows.iter().all(|row| {
                row.get("bid_amount").is_some_and(non_null)
                    && row.get("currency").is_some_and(non_null)
            });
        output.push(json!({
            "id": notice_id,
            "agency_id": field(notice,"agency_id"),
            "noticed_at": field(notice,"published_on"),
            "participant_set_complete": participant_complete,
            "winner_complete": winner.is_some(),
            "price_coverage_complete": price_complete,
            "winner_supplier_id": winner.unwrap_or(Value::Null),
            "participants": participants.rows,
        }));
    }
    Ok(output)
}

#[derive(Clone, Copy)]
enum ParticipantShape {
    Ownership,
    Bid,
}

struct ParticipantRows {
    rows: Vec<Value>,
    coverage_complete: bool,
}

fn participant_rows(
    frozen: &Value,
    notice_id: &Value,
    shape: ParticipantShape,
) -> Result<ParticipantRows, Failure> {
    let mut output = Vec::new();
    let mut coverage_complete = true;
    for row in frozen_array(frozen, "bidder_participations")? {
        let row = object(row, "bidder_participations")?;
        if row.get("notice_id") != Some(notice_id) {
            continue;
        }
        coverage_complete &= field_text(row, "coverage_status") == Some("COMPLETE");
        let mut participant = Map::new();
        participant.insert("supplier_id".to_owned(), field(row, "supplier_id"));
        match shape {
            ParticipantShape::Ownership => {
                participant.insert(
                    "participation_status".to_owned(),
                    field(row, "participation_status"),
                );
                participant.insert("identity_status".to_owned(), field(row, "identity_status"));
            }
            ParticipantShape::Bid => {
                participant.insert(
                    "bid_amount".to_owned(),
                    decimal_as_string(&field(row, "bid_amount")),
                );
                participant.insert("currency".to_owned(), field(row, "currency"));
            }
        }
        output.push(Value::Object(participant));
    }
    Ok(ParticipantRows {
        rows: output,
        coverage_complete,
    })
}

fn supplier_identity_statuses(frozen: &Value) -> Result<BTreeMap<&str, Value>, Failure> {
    let mut statuses = BTreeMap::new();
    for row in frozen_array(frozen, "suppliers")? {
        let row = object(row, "suppliers")?;
        let Some(supplier_id) = field_text(row, "id") else {
            continue;
        };
        if statuses
            .insert(supplier_id, field(row, "identity_status"))
            .is_some()
        {
            return Err(materialization_invalid("duplicate supplier identity"));
        }
    }
    Ok(statuses)
}

#[path = "analysis_rule_conflict_projection.rs"]
mod projection;
use projection::*;

#[cfg(test)]
#[path = "analysis_rule_conflict_materializer_tests.rs"]
mod tests;
