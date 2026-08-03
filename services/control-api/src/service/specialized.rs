use super::*;

pub(super) async fn apply_specialized(
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match specialized_group(operation) {
        Some(1) => {
            apply_specialized_group_1(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(2) => {
            apply_specialized_group_2(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(3) => {
            apply_specialized_group_3(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(4) => {
            apply_specialized_group_4(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(5) => {
            apply_specialized_group_5(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(6) => {
            apply_specialized_group_6(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        Some(7) => {
            apply_specialized_group_7(operation, payload, id, actor, session_id, field_keys, tx)
                .await?
        }
        _ => {}
    }
    Ok(())
}

const SPECIALIZED_GROUPS: [&[&str]; 7] = [
    &[
        "acceptAgentSuggestion",
        "rejectAgentSuggestion",
        "activateRuleVersion",
        "scheduleRuleActivation",
        "addClaim",
        "addEvidence",
        "assignCorrection",
        "assignReview",
        "createResponseRequest",
        "createRuleVersionDraft",
        "createCorrection",
        "createEvidenceRedaction",
        "createHypothesis",
    ],
    &[
        "createRetractionDraft",
        "createReviewSnapshot",
        "approveResponseExcerpt",
        "approveSchemaMapping",
        "rejectSchemaMapping",
        "assignCase",
        "assignSignal",
        "acknowledgeSourceIncident",
        "createAccessRequest",
        "createSavedView",
        "updateSavedView",
        "deleteSavedView",
        "disableProviderRouting",
    ],
    &[
        "disableUser",
        "grantRole",
        "inviteUser",
        "linkEvidence",
        "linkSignalToCase",
        "pauseBackfill",
        "pauseJobQueue",
        "pauseSource",
        "placeTemporaryRestriction",
        "previewPublication",
        "publishCase",
    ],
    &[
        "reassignTask",
        "proposeRoleDefinitionChange",
        "revokeRole",
        "retryJob",
        "retryJobs",
        "retrySourceRun",
        "rollbackRuleVersion",
        "runRuleEvaluation",
        "resolveCorrectionRequest",
        "saveResponseRequestDraft",
        "startAccessReview",
    ],
    &[
        "startAgentRun",
        "startBackfill",
        "startRuleShadow",
        "startSourceRun",
        "submitReview",
        "testProviderConnection",
        "transitionCase",
        "triageCorrection",
        "triageSignal",
    ],
    &[
        "unlinkSignalFromCase",
        "updateBudgetLimit",
        "updateClaim",
        "updateCorrectionDraft",
        "updateEvidence",
        "updateHypothesis",
        "validateClaims",
        "verifyAuditIntegrity",
        "verifyEvidence",
        "createAuditExport",
        "placeLegalHold",
        "activateKillSwitch",
        "deactivateKillSwitch",
        "extendKillSwitch",
        "markNotificationRead",
    ],
    &[
        "revokeOwnSession",
        "revokeUserSessions",
        "cancelJob",
        "quarantineJob",
    ],
];

fn specialized_group(operation: &str) -> Option<usize> {
    SPECIALIZED_GROUPS
        .iter()
        .position(|group| group.contains(&operation))
        .map(|index| index + 1)
}
