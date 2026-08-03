use serde_json::Value;
use thiserror::Error;

use crate::{
    policy::{EvaluationContext, PolicyError, evaluate},
    prompt_isolation::{PromptError, rendered_hash},
    providers::{DeterministicProvider, Provider, ProviderError, route},
    schema_validation::{ObjectSchema, SchemaValidationError, validate_object},
};

const EVALUATION_BUNDLE: &str = include_str!("../../../verification/agent-eval-bundle.json");

#[derive(Debug, Error)]
pub enum ProviderDoubleError {
    #[error("embedded provider-double bundle is invalid")]
    InvalidBundle,
    #[error("embedded provider-double case is missing")]
    CaseMissing,
    #[error("provider-double prompt binding failed")]
    Prompt(#[from] PromptError),
    #[error("provider-double prompt digest differs from authority")]
    PromptDigestMismatch,
    #[error("provider-double output schema validation failed")]
    Schema(#[from] SchemaValidationError),
    #[error("provider-double policy evaluation failed")]
    Policy(#[from] PolicyError),
}

#[derive(Debug)]
pub struct ProviderDoubleExecution {
    pub case_id: String,
    pub output: Value,
    pub selected_provider: Option<String>,
    pub provider_attempts: usize,
    pub schema_validations: usize,
    pub network_calls: usize,
}

pub fn embedded_case_ids() -> Result<Vec<String>, ProviderDoubleError> {
    cases()?
        .iter()
        .map(|case| {
            case.get("case_id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or(ProviderDoubleError::InvalidBundle)
        })
        .collect()
}

pub fn embedded_provider_response(case_id: &str) -> Result<Value, ProviderDoubleError> {
    case(case_id)?
        .get("provider")
        .cloned()
        .ok_or(ProviderDoubleError::InvalidBundle)
}

pub fn execute_embedded_case(
    case_id: &str,
) -> Result<ProviderDoubleExecution, ProviderDoubleError> {
    let case = case(case_id)?;
    let agent_id = string_field(&case, "agent_id")?;
    let scenario = object_field(&case, "scenario")?;
    let input = object_field(&case, "input")?;
    let provider_output = object_field(&case, "provider")?;
    let transcript = object_field(&case, "transcript")?;
    let prompt = string_field(&case, "prompt")?;
    let expected_prompt_sha256 = scenario
        .get("expected_prompt_sha256")
        .and_then(Value::as_str)
        .ok_or(ProviderDoubleError::InvalidBundle)?;
    if rendered_hash(prompt, input)? != expected_prompt_sha256 {
        return Err(ProviderDoubleError::PromptDigestMismatch);
    }

    let attempts = provider_attempts(scenario, provider_output)?;
    let provider_attempt_count = attempts.len();
    let provider_refs = attempts
        .iter()
        .map(|provider| provider as &dyn Provider)
        .collect::<Vec<_>>();
    let routed = route(&provider_refs, input);
    let (selected_provider, output_for_policy, provider_schema_validations) = match routed {
        Ok((provider_id, output)) => {
            validate_authority_agent_output(agent_id, &output)?;
            (Some(provider_id.to_owned()), output, 1)
        }
        Err(ProviderError::Unavailable) => (None, provider_output.clone(), 0),
        Err(ProviderError::InvalidOutput) => {
            return Err(ProviderDoubleError::Schema(
                SchemaValidationError::NotObject,
            ));
        }
    };
    let output = evaluate(EvaluationContext {
        agent_id,
        scenario,
        input,
        provider_output: &output_for_policy,
        transcript,
    })?;
    validate_authority_agent_output(agent_id, &output)?;
    Ok(ProviderDoubleExecution {
        case_id: case_id.to_owned(),
        output,
        selected_provider,
        provider_attempts: provider_attempt_count,
        schema_validations: provider_schema_validations + 1,
        network_calls: 0,
    })
}

fn cases() -> Result<Vec<Value>, ProviderDoubleError> {
    serde_json::from_str(EVALUATION_BUNDLE).map_err(|_| ProviderDoubleError::InvalidBundle)
}

fn case(case_id: &str) -> Result<Value, ProviderDoubleError> {
    cases()?
        .into_iter()
        .find(|candidate| candidate.get("case_id").and_then(Value::as_str) == Some(case_id))
        .ok_or(ProviderDoubleError::CaseMissing)
}

fn provider_attempts(
    scenario: &Value,
    provider_output: &Value,
) -> Result<Vec<DeterministicProvider>, ProviderDoubleError> {
    let attempts = scenario
        .get("provider_attempts")
        .and_then(Value::as_array)
        .ok_or(ProviderDoubleError::InvalidBundle)?;
    let max_iterations = scenario
        .get("max_iterations")
        .and_then(Value::as_u64)
        .unwrap_or(4) as usize;
    attempts
        .iter()
        .take(max_iterations)
        .map(|attempt| {
            let provider_id = string_field(attempt, "provider")?.to_owned();
            let outcome = match string_field(attempt, "status")? {
                "OK" => Ok(provider_output.clone()),
                "UNAVAILABLE" => Err(ProviderError::Unavailable),
                _ => Err(ProviderError::InvalidOutput),
            };
            Ok(DeterministicProvider {
                provider_id,
                outcome,
            })
        })
        .collect()
}

pub fn validate_authority_agent_output(
    agent_id: &str,
    output: &Value,
) -> Result<(), SchemaValidationError> {
    let required = &[
        "status",
        "summary",
        "citations",
        "unknowns",
        "abstention_reasons",
    ];
    let allowed = match agent_id {
        "market-researcher" => &[
            "status",
            "summary",
            "citations",
            "unknowns",
            "abstention_reasons",
            "recommended_actions",
            "comparables",
        ][..],
        "investigator" => &[
            "status",
            "summary",
            "citations",
            "unknowns",
            "abstention_reasons",
            "recommended_actions",
            "hypotheses",
        ][..],
        "skeptic" => &[
            "status",
            "summary",
            "citations",
            "unknowns",
            "abstention_reasons",
            "recommended_actions",
            "challenges",
        ][..],
        "claim-drafter" => &[
            "status",
            "summary",
            "citations",
            "unknowns",
            "abstention_reasons",
            "recommended_actions",
            "claims",
        ][..],
        "citation-verifier" => &[
            "status",
            "summary",
            "citations",
            "unknowns",
            "abstention_reasons",
            "recommended_actions",
            "claim_results",
        ][..],
        _ => return Err(SchemaValidationError::UnknownField),
    };
    validate_object(output, ObjectSchema { required, allowed })?;
    validate_common_fields(output)?;
    match agent_id {
        "market-researcher" => validate_market_research(output),
        "investigator" => validate_investigator(output),
        "skeptic" => validate_skeptic(output),
        "claim-drafter" => validate_claim_drafter(output),
        "citation-verifier" => validate_citation_verifier(output),
        _ => Err(SchemaValidationError::UnknownField),
    }
}

fn validate_common_fields(output: &Value) -> Result<(), SchemaValidationError> {
    if !matches!(
        output.get("status").and_then(Value::as_str),
        Some("COMPLETED" | "ABSTAINED" | "POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || output
        .get("summary")
        .and_then(Value::as_str)
        .is_none_or(|value| value.chars().count() > 6000)
    {
        return Err(SchemaValidationError::InvalidField);
    }
    text_array(output.get("unknowns"))?;
    text_array(output.get("abstention_reasons"))?;
    for citation in array(output.get("citations"))? {
        validate_object(
            citation,
            ObjectSchema {
                required: &["evidence_id", "locator", "supports"],
                allowed: &["evidence_id", "locator", "supports"],
            },
        )?;
        uuid_field(citation, "evidence_id")?;
        string_field_value(citation, "locator")?;
        string_field_value(citation, "supports")?;
    }
    if let Some(actions) = output.get("recommended_actions") {
        for action in array(Some(actions))? {
            validate_object(
                action,
                ObjectSchema {
                    required: &["action_type", "reason"],
                    allowed: &["action_type", "reason", "target"],
                },
            )?;
            string_field_value(action, "action_type")?;
            string_field_value(action, "reason")?;
            if action.get("target").is_some() {
                string_field_value(action, "target")?;
            }
        }
    }
    Ok(())
}

fn validate_market_research(output: &Value) -> Result<(), SchemaValidationError> {
    for item in optional_array(output, "comparables")? {
        let fields = [
            "source_url",
            "observed_at",
            "unit",
            "unit_price",
            "compatibility",
            "limitations",
        ];
        validate_object(
            item,
            ObjectSchema {
                required: &fields,
                allowed: &fields,
            },
        )?;
        for field in ["source_url", "observed_at", "unit", "unit_price"] {
            string_field_value(item, field)?;
        }
        if !matches!(
            item.get("compatibility").and_then(Value::as_str),
            Some("POTENTIAL" | "INCOMPATIBLE" | "UNKNOWN")
        ) {
            return Err(SchemaValidationError::InvalidField);
        }
        text_array(item.get("limitations"))?;
    }
    Ok(())
}

fn validate_investigator(output: &Value) -> Result<(), SchemaValidationError> {
    for item in optional_array(output, "hypotheses")? {
        let fields = [
            "statement",
            "supporting_evidence_ids",
            "contradicting_evidence_ids",
            "unknowns",
        ];
        validate_object(
            item,
            ObjectSchema {
                required: &fields,
                allowed: &fields,
            },
        )?;
        string_field_value(item, "statement")?;
        uuid_array(item.get("supporting_evidence_ids"))?;
        uuid_array(item.get("contradicting_evidence_ids"))?;
        text_array(item.get("unknowns"))?;
    }
    Ok(())
}

fn validate_skeptic(output: &Value) -> Result<(), SchemaValidationError> {
    for item in optional_array(output, "challenges")? {
        let fields = [
            "claim_or_hypothesis",
            "challenge",
            "evidence_ids",
            "severity",
        ];
        validate_object(
            item,
            ObjectSchema {
                required: &fields,
                allowed: &fields,
            },
        )?;
        string_field_value(item, "claim_or_hypothesis")?;
        string_field_value(item, "challenge")?;
        uuid_array(item.get("evidence_ids"))?;
        if !matches!(
            item.get("severity").and_then(Value::as_str),
            Some("INFO" | "MATERIAL" | "BLOCKING")
        ) {
            return Err(SchemaValidationError::InvalidField);
        }
    }
    Ok(())
}

fn validate_claim_drafter(output: &Value) -> Result<(), SchemaValidationError> {
    for item in optional_array(output, "claims")? {
        let fields = [
            "claim_type",
            "text",
            "evidence_ids",
            "response_ids",
            "limitations",
        ];
        validate_object(
            item,
            ObjectSchema {
                required: &fields,
                allowed: &fields,
            },
        )?;
        if !matches!(
            item.get("claim_type").and_then(Value::as_str),
            Some("FACT" | "CALCULATION" | "INFERENCE" | "LIMITATION" | "OFFICIAL_OUTCOME")
        ) {
            return Err(SchemaValidationError::InvalidField);
        }
        string_field_value(item, "text")?;
        uuid_array(item.get("evidence_ids"))?;
        uuid_array(item.get("response_ids"))?;
        text_array(item.get("limitations"))?;
    }
    Ok(())
}

fn validate_citation_verifier(output: &Value) -> Result<(), SchemaValidationError> {
    for item in optional_array(output, "claim_results")? {
        let fields = [
            "claim_index",
            "status",
            "unsupported_fragments",
            "verified_evidence_ids",
        ];
        validate_object(
            item,
            ObjectSchema {
                required: &fields,
                allowed: &fields,
            },
        )?;
        if item.get("claim_index").and_then(Value::as_u64).is_none()
            || !matches!(
                item.get("status").and_then(Value::as_str),
                Some("VERIFIED" | "UNSUPPORTED" | "PARTIAL")
            )
        {
            return Err(SchemaValidationError::InvalidField);
        }
        text_array(item.get("unsupported_fragments"))?;
        uuid_array(item.get("verified_evidence_ids"))?;
    }
    Ok(())
}

fn optional_array<'a>(
    output: &'a Value,
    field: &str,
) -> Result<&'a [Value], SchemaValidationError> {
    output
        .get(field)
        .map_or(Ok(&[][..]), |value| array(Some(value)))
}

fn array(value: Option<&Value>) -> Result<&[Value], SchemaValidationError> {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(SchemaValidationError::InvalidField)
}

fn text_array(value: Option<&Value>) -> Result<(), SchemaValidationError> {
    if array(value)?.iter().all(Value::is_string) {
        Ok(())
    } else {
        Err(SchemaValidationError::InvalidField)
    }
}

fn uuid_array(value: Option<&Value>) -> Result<(), SchemaValidationError> {
    if array(value)?.iter().all(|item| {
        item.as_str()
            .and_then(|value| uuid::Uuid::parse_str(value).ok())
            .is_some()
    }) {
        Ok(())
    } else {
        Err(SchemaValidationError::InvalidField)
    }
}

fn uuid_field(value: &Value, field: &str) -> Result<(), SchemaValidationError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .map(|_| ())
        .ok_or(SchemaValidationError::InvalidField)
}

fn string_field_value(value: &Value, field: &str) -> Result<(), SchemaValidationError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(|_| ())
        .ok_or(SchemaValidationError::InvalidField)
}

fn object_field<'a>(value: &'a Value, name: &str) -> Result<&'a Value, ProviderDoubleError> {
    value
        .get(name)
        .filter(|field| field.is_object())
        .ok_or(ProviderDoubleError::InvalidBundle)
}

fn string_field<'a>(value: &'a Value, name: &str) -> Result<&'a str, ProviderDoubleError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .ok_or(ProviderDoubleError::InvalidBundle)
}
