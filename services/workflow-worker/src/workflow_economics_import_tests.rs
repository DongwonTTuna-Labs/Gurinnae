use super::*;

fn digest(byte: char) -> String {
    std::iter::repeat_n(byte, 64).collect()
}

fn authorization_payload(execution_id: Uuid) -> Value {
    json!({
        "executionId":execution_id,
        "generation":1,
        "actionKind":ECONOMICS_ACTION_KIND,
        "decisionDigest":digest('a'),
        "executionDigest":digest('b'),
        "targetCommand":ECONOMICS_TARGET_COMMAND,
        "targetRequestSha256":digest('c'),
        "expiresAt":"2027-01-01T00:00:00Z",
    })
}

fn economics_execution() -> ApprovedExecution {
    let execution_id = Uuid::from_u128(1);
    ApprovedExecution {
        execution_id,
        generation: 1,
        event_payload: authorization_payload(execution_id),
        kind: ApprovedExecutionKind::EconomicsImport,
    }
}

#[test]
fn economics_authorization_is_exact_digest_bound_and_closed() -> Result<(), Failure> {
    let execution = economics_execution();
    let parsed = economics_authorization_event(Uuid::from_u128(2), &execution)?;
    assert_eq!(parsed.execution_id, execution.execution_id);
    assert_eq!(parsed.generation, 1);
    assert_eq!(parsed.decision_digest, digest('a'));
    assert_eq!(parsed.execution_digest, digest('b'));
    assert_eq!(parsed.target_request_sha256, digest('c'));
    assert!(parsed.expires_at > time::OffsetDateTime::UNIX_EPOCH);

    let mut additional = economics_execution();
    additional.event_payload["rawEvidence"] = json!("must-not-cross-boundary");
    assert!(economics_authorization_event(Uuid::from_u128(2), &additional).is_err());

    for field in ["decisionDigest", "executionDigest", "targetRequestSha256"] {
        let mut invalid = economics_execution();
        invalid.event_payload[field] = json!("not-a-digest");
        assert!(economics_authorization_event(Uuid::from_u128(2), &invalid).is_err());
    }

    let mut wrong_generation = economics_execution();
    wrong_generation.generation = 2;
    wrong_generation.event_payload["generation"] = json!(2);
    assert!(economics_authorization_event(Uuid::from_u128(2), &wrong_generation).is_err());

    let mut nil_execution = economics_execution();
    nil_execution.execution_id = Uuid::nil();
    nil_execution.event_payload["executionId"] = json!(Uuid::nil());
    assert!(economics_authorization_event(Uuid::from_u128(2), &nil_execution).is_err());
    Ok(())
}

#[test]
fn economics_dispatch_requires_the_exact_action_and_private_command() -> Result<(), Failure> {
    let execution_id = Uuid::from_u128(1);
    let payload = authorization_payload(execution_id);
    let parsed = approved_execution(
        payload
            .as_object()
            .ok_or_else(|| invalid_economics_execution("test payload"))?,
        execution_id,
    )?;
    assert_eq!(parsed.kind, ApprovedExecutionKind::EconomicsImport);

    for (action_kind, target_command) in [
        ("ECONOMICS_IMPORT", "recordRevenue"),
        ("COMMUNICATION", ECONOMICS_TARGET_COMMAND),
    ] {
        let mut invalid = authorization_payload(execution_id);
        invalid["actionKind"] = json!(action_kind);
        invalid["targetCommand"] = json!(target_command);
        assert!(
            approved_execution(
                invalid
                    .as_object()
                    .ok_or_else(|| invalid_economics_execution("test payload"))?,
                execution_id,
            )
            .is_err()
        );
    }
    Ok(())
}

#[test]
fn economics_execution_rejects_missing_or_stale_job_fences() {
    let valid = ProducerJobFence {
        id: Uuid::from_u128(1),
        lease_token: Uuid::from_u128(2),
        fencing_token: 3,
        lease_expires_at: time::OffsetDateTime::from_unix_timestamp(1_800_000_000)
            .unwrap_or(time::OffsetDateTime::UNIX_EPOCH),
    };
    assert!(validate_economics_producer_fence(valid, "workflow-worker-1").is_ok());
    for invalid in [
        ProducerJobFence {
            id: Uuid::nil(),
            ..valid
        },
        ProducerJobFence {
            lease_token: Uuid::nil(),
            ..valid
        },
        ProducerJobFence {
            fencing_token: 0,
            ..valid
        },
    ] {
        assert!(validate_economics_producer_fence(invalid, "workflow-worker-1").is_err());
    }
    assert!(validate_economics_producer_fence(valid, "").is_err());
    assert!(validate_economics_producer_fence(valid, " whitespace ").is_err());
}

#[test]
fn economics_database_errors_are_redacted_and_fail_closed() {
    for sqlstate in [Some("22023"), Some("23505"), Some("55000"), Some("P0001")] {
        let failure = economics_owner_sqlstate_failure(sqlstate);
        assert!(matches!(failure, Failure::Terminal(_, _)));
        let Failure::Terminal(_, detail) = failure else {
            return;
        };
        assert_eq!(
            detail,
            format!("redacted:sqlstate={}", sqlstate.unwrap_or_default())
        );
    }
    for sqlstate in [Some("40001"), Some("40P01"), Some("08006"), None] {
        let failure = economics_owner_sqlstate_failure(sqlstate);
        assert!(matches!(failure, Failure::Retryable(_, _)));
    }
}

#[test]
fn owner_transport_ambiguity_never_becomes_generic_job_failure() {
    let correlation_digest = digest('d');
    for sqlstate in [Some("40001"), Some("40P01")] {
        let failure =
            economics_owner_call_sqlstate_failure(sqlstate, "COMPLETE", correlation_digest.clone());
        assert!(matches!(failure, Failure::Retryable(_, _)));
    }
    // Semantic 55000/22023 outcomes must arrive as an exact owner receipt. A
    // raw database error has no receipt and must never be synthesized into a
    // terminal business result by the worker.
    for sqlstate in [
        Some("08006"),
        Some("22023"),
        Some("23514"),
        Some("42501"),
        Some("55000"),
        None,
    ] {
        for phase in ["CLAIM", "COMPLETE", "FAIL"] {
            let failure =
                economics_owner_call_sqlstate_failure(sqlstate, phase, correlation_digest.clone());
            assert!(matches!(
                failure,
                Failure::OwnerOutcomeUnknown(actual_phase, ref detail)
                    if actual_phase == phase && detail == &correlation_digest
            ));
        }
    }
}

#[test]
fn dedicated_pool_identity_check_names_only_the_importer_role() {
    assert!(ECONOMICS_ROLE_CHECK_SQL.contains(ECONOMICS_DATABASE_ROLE));
    assert!(ECONOMICS_ROLE_CHECK_SQL.contains("session_user='gurine_economics_importer'"));
    assert!(ECONOMICS_ROLE_CHECK_SQL.contains("current_user='gurine_economics_importer'"));
    assert!(!ECONOMICS_ROLE_CHECK_SQL.contains("gurine_workflow_worker"));
    assert!(!ECONOMICS_ROLE_CHECK_SQL.contains("gurine_billing_gateway"));
    assert!(!ECONOMICS_ROLE_CHECK_SQL.contains("gurine_economics_writer"));
}

#[test]
fn wrong_session_or_effective_principal_is_rejected() {
    assert!(economics_principals_are_dedicated(true, true));
    for (session_user_matches, current_user_matches) in
        [(false, true), (true, false), (false, false)]
    {
        assert!(!economics_principals_are_dedicated(
            session_user_matches,
            current_user_matches,
        ));
    }
}

#[test]
fn absent_economics_database_preserves_non_economics_execution_routes() {
    for kind in [
        ApprovedExecutionKind::Communication,
        ApprovedExecutionKind::Hypothesis,
    ] {
        assert!(matches!(economics_pool_for_execution(kind, None), Ok(None)));
    }
}

#[test]
fn absent_economics_database_fails_before_any_owner_call() {
    let failure = economics_pool_for_execution(ApprovedExecutionKind::EconomicsImport, None);
    assert!(matches!(
        failure,
        Err(Failure::Retryable(
            "ECONOMICS_OWNER_ABI_UNAVAILABLE",
            detail,
        )) if detail == "redacted:economics-database-not-configured"
    ));
}

#[test]
fn configured_wrong_economics_role_is_a_startup_failure() {
    assert!(validate_economics_pool_role(true).is_ok());
    assert!(matches!(
        validate_economics_pool_role(false),
        Err(WorkerError::Initialization)
    ));
}

#[test]
fn owner_abi_activation_remains_closed_until_database_contract_is_final() {
    assert!(!ECONOMICS_OWNER_ABI_READY);
}

#[test]
fn owner_sql_uses_the_frozen_positional_abi() {
    assert_eq!(
        ECONOMICS_CLAIM_OWNER_SQL,
        "SELECT ops.claim_economics_import_execution_v1($1,$2,$3,$4,$5,$6,$7,$8,$9)"
    );
    assert_eq!(
        ECONOMICS_COMPLETE_OWNER_SQL,
        "SELECT ops.complete_economics_import_execution_v1($1,$2,$3,$4,$5,$6)"
    );
    assert_eq!(
        ECONOMICS_FAIL_OWNER_SQL,
        "SELECT ops.fail_economics_import_execution_v1($1,$2,$3,$4,$5,$6,$7,$8)"
    );
    for sql in [
        ECONOMICS_CLAIM_OWNER_SQL,
        ECONOMICS_COMPLETE_OWNER_SQL,
        ECONOMICS_FAIL_OWNER_SQL,
    ] {
        assert!(sql.starts_with("SELECT ops."));
        assert!(!sql.contains("INSERT"));
        assert!(!sql.contains("UPDATE"));
        assert!(!sql.contains("DELETE"));
        assert!(!sql.contains("gurine_economics_writer"));
    }
}

#[test]
fn owner_request_identity_is_stable_across_complete_and_fail_recall() {
    let execution = economics_execution();
    let authorization = economics_authorization_event(Uuid::from_u128(90), &execution)
        .unwrap_or_else(|failure| panic!("TEST_FIXTURE authorization: {failure:?}"));
    assert_eq!(
        economics_owner_request_id(authorization),
        Uuid::from_u128(90)
    );
    assert_eq!(
        economics_owner_request_id(authorization),
        economics_owner_request_id(authorization)
    );
}
