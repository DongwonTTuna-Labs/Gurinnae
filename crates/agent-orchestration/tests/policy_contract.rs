use gurine_agent_orchestration::{
    policy::{EvaluationContext, evaluate},
    prompt_isolation::rendered_hash,
};
use serde_json::Value;

#[test]
fn all_fifty_agent_policy_cases_match() -> Result<(), Box<dyn std::error::Error>> {
    let cases: Value =
        serde_json::from_str(include_str!("../../../verification/agent-eval-bundle.json"))?;
    let cases = cases.as_array().ok_or("bundle is not an array")?;
    assert_eq!(cases.len(), 50);
    for case in cases {
        let scenario = case.get("scenario").ok_or("missing scenario")?;
        let input = case.get("input").ok_or("missing input")?;
        let prompt = case
            .get("prompt")
            .and_then(Value::as_str)
            .ok_or("missing prompt")?;
        let expected_prompt_hash = scenario
            .get("expected_prompt_sha256")
            .and_then(Value::as_str)
            .ok_or("missing prompt hash")?;
        assert_eq!(rendered_hash(prompt, input)?, expected_prompt_hash);
        let actual = evaluate(EvaluationContext {
            agent_id: case
                .get("agent_id")
                .and_then(Value::as_str)
                .ok_or("missing agent")?,
            scenario,
            input,
            provider_output: case.get("provider").ok_or("missing provider")?,
            transcript: case.get("transcript").ok_or("missing transcript")?,
        })?;
        assert_eq!(
            actual,
            *case.get("expected").ok_or("missing expected")?,
            "{}",
            case.get("case_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown case")
        );
    }
    Ok(())
}
