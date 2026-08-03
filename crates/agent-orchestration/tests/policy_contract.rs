use gurine_agent_orchestration::provider_double::{embedded_case_ids, execute_embedded_case};
use serde_json::Value;

#[test]
fn all_fifty_agent_policy_cases_match() -> Result<(), Box<dyn std::error::Error>> {
    let expected_cases: Value =
        serde_json::from_str(include_str!("../../../verification/agent-eval-bundle.json"))?;
    let expected_cases = expected_cases.as_array().ok_or("bundle is not an array")?;
    let case_ids = embedded_case_ids()?;
    assert_eq!(case_ids.len(), 50);
    for (case_id, expected_case) in case_ids.iter().zip(expected_cases) {
        let execution = execute_embedded_case(case_id)?;
        assert_eq!(execution.case_id, *case_id);
        assert_eq!(execution.network_calls, 0, "{case_id}");
        assert!(execution.provider_attempts >= 1, "{case_id}");
        assert!(execution.schema_validations >= 1, "{case_id}");
        assert_eq!(
            execution.output,
            *expected_case.get("expected").ok_or("missing expected")?,
            "{case_id}"
        );
    }
    Ok(())
}
