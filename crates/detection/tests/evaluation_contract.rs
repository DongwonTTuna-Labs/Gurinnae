use gurine_detection::engine::evaluate;
use serde_json::Value;

const EVALUATIONS: &[(&str, &str)] = &[
    (
        "bid_rotation",
        include_str!("../../../specs/detection/evals/bid_rotation.jsonl"),
    ),
    (
        "contract_amendment_escalation",
        include_str!("../../../specs/detection/evals/contract_amendment_escalation.jsonl"),
    ),
    (
        "contract_splitting_pattern",
        include_str!("../../../specs/detection/evals/contract_splitting_pattern.jsonl"),
    ),
    (
        "low_bid_competition",
        include_str!("../../../specs/detection/evals/low_bid_competition.jsonl"),
    ),
    (
        "new_supplier_dependence",
        include_str!("../../../specs/detection/evals/new_supplier_dependence.jsonl"),
    ),
    (
        "officer_overlap_award",
        include_str!("../../../specs/detection/evals/officer_overlap_award.jsonl"),
    ),
    (
        "ownership_linked_competitors",
        include_str!("../../../specs/detection/evals/ownership_linked_competitors.jsonl"),
    ),
    (
        "price_outlier",
        include_str!("../../../specs/detection/evals/price_outlier.jsonl"),
    ),
    (
        "repeated_single_source",
        include_str!("../../../specs/detection/evals/repeated_single_source.jsonl"),
    ),
    (
        "restrictive_specification",
        include_str!("../../../specs/detection/evals/restrictive_specification.jsonl"),
    ),
    (
        "revolving_door_contract",
        include_str!("../../../specs/detection/evals/revolving_door_contract.jsonl"),
    ),
    (
        "sanctioned_successor",
        include_str!("../../../specs/detection/evals/sanctioned_successor.jsonl"),
    ),
    (
        "shared_supplier_identity",
        include_str!("../../../specs/detection/evals/shared_supplier_identity.jsonl"),
    ),
    (
        "supplier_concentration",
        include_str!("../../../specs/detection/evals/supplier_concentration.jsonl"),
    ),
    (
        "year_end_spending_spike",
        include_str!("../../../specs/detection/evals/year_end_spending_spike.jsonl"),
    ),
];

#[test]
fn all_four_hundred_fifty_oracle_cases_match() -> Result<(), Box<dyn std::error::Error>> {
    let mut total = 0;
    for (file, contents) in EVALUATIONS {
        for (line_index, line) in contents.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let case: Value = serde_json::from_str(line)?;
            let rule_id = case
                .get("rule_id")
                .and_then(Value::as_str)
                .ok_or("missing rule id")?;
            let input = case.get("input").ok_or("missing input")?;
            let expected = case.get("expected").ok_or("missing expected")?;
            let actual = evaluate(rule_id, input)?;
            assert_eq!(&actual, expected, "{file}:{}", line_index + 1);
            total += 1;
        }
    }
    assert_eq!(total, 450);
    Ok(())
}
