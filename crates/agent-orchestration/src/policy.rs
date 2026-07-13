use std::collections::BTreeSet;

use serde_json::{Value, json};
use thiserror::Error;

const ABSTAIN_SUMMARY: &str = "정책 또는 검증 조건을 충족하지 못해 결론을 생성하지 않았습니다.";

#[derive(Debug, Error)]
pub enum PolicyError {
    #[error("agent policy input is invalid")]
    InvalidInput,
    #[error("agent id is not cataloged")]
    UnknownAgent,
}

pub struct EvaluationContext<'a> {
    pub agent_id: &'a str,
    pub scenario: &'a Value,
    pub input: &'a Value,
    pub provider_output: &'a Value,
    pub transcript: &'a Value,
}

struct ToolInspection {
    cost: i64,
    citation_pairs: BTreeSet<(String, String)>,
    denied: bool,
}

pub fn evaluate(context: EvaluationContext<'_>) -> Result<Value, PolicyError> {
    let allowed_tools = allowed_tools(context.agent_id).ok_or(PolicyError::UnknownAgent)?;
    let inspection = inspect_tools(context.transcript, allowed_tools)?;
    if inspection.denied {
        return Ok(blocked("POLICY_BLOCKED", "TOOL_NOT_ALLOWED"));
    }
    if context.scenario["current_evidence_snapshot_hash"] != context.input["evidence_snapshot_hash"]
    {
        return Ok(blocked("ABSTAINED", "EVIDENCE_SNAPSHOT_STALE"));
    }
    let budget = context.input["budget_krw"]
        .as_i64()
        .ok_or(PolicyError::InvalidInput)?;
    if budget <= 0 {
        return Ok(blocked("BUDGET_BLOCKED", "BUDGET_EXHAUSTED"));
    }
    let flags = context.input["policy_flags"]
        .as_array()
        .ok_or(PolicyError::InvalidInput)?;
    if flags
        .iter()
        .any(|flag| flag.as_str() == Some("prompt_injection_detected"))
    {
        return Ok(blocked("ABSTAINED", "UNTRUSTED_INSTRUCTION_DETECTED"));
    }
    let provider_cost = select_provider_cost(context.scenario)?;
    if provider_cost.is_none() {
        return Ok(blocked("ABSTAINED", "PROVIDER_UNAVAILABLE"));
    }
    if inspection.cost + provider_cost.unwrap_or_default() > budget {
        return Ok(blocked("BUDGET_BLOCKED", "BUDGET_EXHAUSTED"));
    }
    let citations = context.provider_output["citations"]
        .as_array()
        .ok_or(PolicyError::InvalidInput)?;
    if context.scenario["kind"].as_str() == Some("missing_citation") || citations.is_empty() {
        return Ok(blocked("ABSTAINED", "CITATION_REQUIRED"));
    }
    let allowed_evidence = context.input["allowed_evidence_ids"]
        .as_array()
        .ok_or(PolicyError::InvalidInput)?
        .iter()
        .filter_map(Value::as_str)
        .collect::<BTreeSet<_>>();
    for citation in citations {
        let evidence_id = citation["evidence_id"]
            .as_str()
            .ok_or(PolicyError::InvalidInput)?;
        let locator = citation["locator"]
            .as_str()
            .ok_or(PolicyError::InvalidInput)?;
        if !allowed_evidence.contains(evidence_id) {
            return Ok(blocked("ABSTAINED", "EVIDENCE_OUTSIDE_SNAPSHOT"));
        }
        let locators = context.scenario["expected_locator_map"][evidence_id]
            .as_array()
            .ok_or(PolicyError::InvalidInput)?;
        if !locators.iter().any(|value| value.as_str() == Some(locator)) {
            return Ok(blocked("ABSTAINED", "CITATION_LOCATOR_MISMATCH"));
        }
        if !inspection
            .citation_pairs
            .contains(&(evidence_id.to_owned(), locator.to_owned()))
        {
            return Ok(blocked("ABSTAINED", "CITATION_LOCATOR_MISMATCH"));
        }
    }
    Ok(context.provider_output.clone())
}

fn inspect_tools(
    transcript: &Value,
    allowed_tools: &[&str],
) -> Result<ToolInspection, PolicyError> {
    let calls = transcript["calls"]
        .as_array()
        .ok_or(PolicyError::InvalidInput)?;
    let mut cost = 0_i64;
    let mut pairs = BTreeSet::new();
    let mut denied = false;
    for call in calls {
        let tool = call["tool_id"].as_str().ok_or(PolicyError::InvalidInput)?;
        let mode = call["mode"].as_str().ok_or(PolicyError::InvalidInput)?;
        cost += call["cost_krw"].as_i64().unwrap_or_default();
        if !allowed_tools.contains(&tool) || mode != "READ_ONLY" {
            denied = true;
            continue;
        }
        let request_text = serde_json::to_string(&call["request"])
            .map_err(|_| PolicyError::InvalidInput)?
            .to_lowercase();
        if [
            "ignore previous",
            "system prompt",
            "reveal secret",
            "override policy",
        ]
        .iter()
        .any(|token| request_text.contains(token))
        {
            return Ok(ToolInspection {
                cost,
                citation_pairs: pairs,
                denied: true,
            });
        }
        if let Some(results) = call["response"]["results"].as_array() {
            for result in results {
                if let (Some(id), Some(locator)) =
                    (result["id"].as_str(), result["locator"].as_str())
                {
                    pairs.insert((id.to_owned(), locator.to_owned()));
                }
            }
        }
    }
    Ok(ToolInspection {
        cost,
        citation_pairs: pairs,
        denied,
    })
}

fn select_provider_cost(scenario: &Value) -> Result<Option<i64>, PolicyError> {
    let fallback = json!([{
        "provider": "primary",
        "status": scenario["provider_status"].as_str().unwrap_or("OK"),
        "cost_krw": 0,
    }]);
    let attempts = scenario
        .get("provider_attempts")
        .filter(|value| !value.is_null())
        .unwrap_or(&fallback);
    let attempts = attempts.as_array().ok_or(PolicyError::InvalidInput)?;
    let max_iterations = scenario["max_iterations"].as_u64().unwrap_or(4) as usize;
    let mut cost = 0_i64;
    for attempt in attempts.iter().take(max_iterations) {
        cost += attempt["cost_krw"].as_i64().unwrap_or_default();
        if attempt["status"].as_str() == Some("OK") {
            return Ok(Some(cost));
        }
    }
    Ok(None)
}

fn blocked(status: &str, reason: &str) -> Value {
    json!({
        "status": status,
        "summary": ABSTAIN_SUMMARY,
        "citations": [],
        "unknowns": [],
        "abstention_reasons": [reason],
        "recommended_actions": [],
    })
}

fn allowed_tools(agent_id: &str) -> Option<&'static [&'static str]> {
    match agent_id {
        "market-researcher" => Some(&[
            "evidence.search",
            "source.fetch",
            "contract.find_comparables",
        ]),
        "investigator" => Some(&[
            "evidence.search",
            "evidence.read",
            "contract.find_comparables",
            "entity.lookup",
        ]),
        "skeptic" => Some(&["evidence.search", "evidence.read", "rule.reproduce"]),
        "claim-drafter" => Some(&["evidence.read", "response.read", "claim.language_check"]),
        "citation-verifier" => Some(&["evidence.read", "source.locator_verify"]),
        _ => None,
    }
}
