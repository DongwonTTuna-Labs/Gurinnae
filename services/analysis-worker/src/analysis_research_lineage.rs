use super::*;

const DIRECT_RESEARCH_ARTIFACT_MODEL_INPUT: bool = false;

pub(super) async fn insert_research_artifact_model_inputs(
    _executor: &mut sqlx::PgConnection,
    _turn: &ProviderTurnIdentity,
    _receipt_id: Uuid,
    _receipt_sha256: &str,
) -> Result<(), Failure> {
    // ResearchArtifact is immutable unreviewed input, never Evidence. Even a
    // later HUMAN_PROMOTED receipt does not expose the original object bytes
    // directly: the promoted, explicitly classified Evidence segment must
    // re-enter through the existing snapshot-bound Evidence source-use path.
    if DIRECT_RESEARCH_ARTIFACT_MODEL_INPUT {
        return Err(Failure::Terminal(
            "AGENT_RESEARCH_ARTIFACT_MODEL_INPUT_FORBIDDEN",
            "direct artifact lineage".to_owned(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::DIRECT_RESEARCH_ARTIFACT_MODEL_INPUT;

    #[test]
    fn research_artifact_never_becomes_direct_model_input() {
        const { assert!(!DIRECT_RESEARCH_ARTIFACT_MODEL_INPUT) };
    }
}
