use super::citation_eligibility;

#[test]
fn citation_policy_keeps_unreviewed_artifacts_inside_hypotheses() {
    let hypothesis_result = citation_eligibility("HYPOTHESIS");
    assert!(hypothesis_result.is_ok());
    let Ok(hypothesis) = hypothesis_result else {
        return;
    };
    assert!(hypothesis.internal_evidence);
    assert!(hypothesis.official_unreviewed_artifact);

    for proposal_type in ["CLAIM", "COMMUNICATION", "TASK", "COMPARABLE"] {
        let policy_result = citation_eligibility(proposal_type);
        assert!(policy_result.is_ok());
        let Ok(policy) = policy_result else {
            return;
        };
        assert!(!policy.official_unreviewed_artifact);
    }
    assert!(citation_eligibility("PUBLICATION").is_err());
}
