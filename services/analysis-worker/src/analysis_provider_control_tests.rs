use super::*;

fn hash(byte: char) -> String {
    std::iter::repeat_n(byte, 64).collect()
}

fn claim(operation_id: &str) -> Value {
    let mut value = json!({
        "schemaVersion":PROVIDER_CONTROL_CLAIM_SCHEMA,
        "executionId":"00000000-0000-4000-8000-000000000001",
        "generation":1,
        "attemptId":"00000000-0000-4000-8000-000000000002",
        "fencingToken":3,
        "executionDigest":hash('a'),
        "approvalDigest":hash('b'),
        "actionDetailDigest":hash('c'),
        "targetRequestSha256":hash('d'),
        "operationId":operation_id,
        "providerId":"00000000-0000-4000-8000-000000000003",
        "providerReference":"relay",
        "expectedProviderVersion":7,
        "creatorActorId":"00000000-0000-4000-8000-000000000004",
        "providerRoutingSnapshot":{
            "providerType":"relay",
            "enabled":true,
            "routingPolicy":{"targetUrl":"https://relay.example.test/v1/chat/completions"},
            "dataRetentionPolicy":"ZERO_RETENTION",
            "version":7
        },
        "providerConfigurationDigest":hash('e'),
        "providerIdempotencyKeySha256":hash('f'),
        "expiresAt":"2027-01-01T00:00:00Z"
    });
    match operation_id {
        "disableProviderRouting" => {
            value["reasonDigest"] = json!(hash('1'));
        }
        "testProviderConnection" => {
            value["testModel"] = json!("gpt-current");
        }
        "upgradeProviderModel" => {
            value["reasonDigest"] = json!(hash('1'));
            value["targetModelId"] = json!("gpt-new");
            value["requestedDataPolicy"] = Value::Null;
        }
        "setModelAutoUpgrade" => {
            value["reasonDigest"] = json!(hash('1'));
            value["autoUpgradeEnabled"] = json!(true);
            value["autoUpgradeTrack"] = json!("gpt-");
        }
        _ => {}
    }
    value
}

fn provider_control_event_job(consumer_id: &str) -> ClaimedJob {
    let execution_id = "00000000-0000-4000-8000-000000000011";
    ClaimedJob {
        id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0010),
        job_type: "EVENT_DELIVERY".to_owned(),
        queue: "analysis-worker".to_owned(),
        payload: json!({
            "consumerId":consumer_id,
            "eventType":"action.execution_authorized.v1",
            "eventId":"00000000-0000-4000-8000-000000000012",
            "aggregateId":execution_id,
            "payload":{
                "actionKind":PROVIDER_CONTROL_ACTION_KIND,
                "executionId":execution_id,
                "generation":1,
                "executionDigest":hash('a'),
                "targetCommand":PROVIDER_CONTROL_TARGET_COMMAND,
                "targetRequestSha256":hash('b'),
            },
        }),
        attempt: 1,
        max_attempts: 8,
        fence: gurine_jobs::fencing::Fence {
            lease_token: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0013),
            fencing_token: 1,
        },
        lease_expires_at: time::OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(1),
    }
}

#[test]
fn provider_control_operation_catalog_is_closed() -> Result<(), Failure> {
    for operation_id in [
        "disableProviderRouting",
        "testProviderConnection",
        "upgradeProviderModel",
        "setModelAutoUpgrade",
    ] {
        parse_provider_control_claim(&claim(operation_id))?;
    }
    assert!(parse_provider_control_claim(&claim("inventedProviderOperation")).is_err());
    let mut extra = claim("disableProviderRouting");
    extra["invented"] = json!(true);
    assert!(parse_provider_control_claim(&extra).is_err());
    Ok(())
}

#[test]
fn provider_control_delivery_requires_the_logical_consumer_identity() -> Result<(), Failure> {
    let job = provider_control_event_job(PROVIDER_CONTROL_CONSUMER);
    let binding = provider_control_event_binding(&job)?;
    assert_eq!(
        binding.execution_id,
        Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0011),
    );
    assert_eq!(
        event_delivery_inbox_consumer(&job),
        PROVIDER_CONTROL_CONSUMER,
    );

    let legacy_job = provider_control_event_job("analysis-worker");
    assert!(provider_control_event_binding(&legacy_job).is_err());
    assert_eq!(
        event_delivery_inbox_consumer(&legacy_job),
        "analysis-worker"
    );
    Ok(())
}

#[test]
fn provider_control_branches_are_classified_exactly() -> Result<(), Failure> {
    assert_eq!(
        parse_provider_control_claim(&claim("disableProviderRouting"))?.branch,
        ProviderControlBranch::Disable,
    );
    assert_eq!(
        parse_provider_control_claim(&claim("testProviderConnection"))?.branch,
        ProviderControlBranch::Test {
            model: "gpt-current".to_owned(),
        },
    );
    assert_eq!(
        parse_provider_control_claim(&claim("upgradeProviderModel"))?.branch,
        ProviderControlBranch::Upgrade {
            model: "gpt-new".to_owned(),
        },
    );
    assert_eq!(
        parse_provider_control_claim(&claim("setModelAutoUpgrade"))?.branch,
        ProviderControlBranch::AutoUpgrade {
            enabled: true,
            track: Some("gpt-".to_owned()),
        },
    );
    Ok(())
}

#[test]
fn relay_target_comes_from_the_bound_routing_policy_snapshot() -> Result<(), Failure> {
    for operation_id in ["testProviderConnection", "upgradeProviderModel"] {
        let parsed = parse_provider_control_claim(&claim(operation_id))?;
        assert_eq!(
            provider_control_relay_target(&parsed)?,
            "https://relay.example.test/v1/chat/completions",
        );
    }

    let mut root_side_door = claim("testProviderConnection");
    root_side_door["providerRoutingSnapshot"]["targetUrl"] =
        json!("https://unbound.example.test/v1/chat/completions");
    root_side_door["providerRoutingSnapshot"]["routingPolicy"] = json!({});
    let parsed = parse_provider_control_claim(&root_side_door)?;
    assert!(provider_control_relay_target(&parsed).is_err());
    Ok(())
}

#[test]
fn requested_policy_is_four_key_canonical_and_digest_bound() -> Result<(), Failure> {
    let policy_configuration = json!({
        "policyVersion":"relay-policy-v1",
        "processingRegion":"KR",
        "retentionMode":"ZERO_RETENTION",
    });
    let mut with_policy = claim("upgradeProviderModel");
    with_policy["requestedDataPolicy"] = json!({
        "processingRegion":"KR",
        "retentionMode":"ZERO_RETENTION",
        "policyVersion":"relay-policy-v1",
        "policySha256":sha256(&canonical_bytes(&policy_configuration)?),
    });
    parse_provider_control_claim(&with_policy)?;

    let mut missing_key = with_policy.clone();
    let removed_policy_version = missing_key["requestedDataPolicy"]
        .as_object_mut()
        .and_then(|policy| policy.remove("policyVersion"));
    assert_eq!(removed_policy_version, Some(json!("relay-policy-v1")));
    assert!(parse_provider_control_claim(&missing_key).is_err());

    let mut extra_key = with_policy.clone();
    extra_key["requestedDataPolicy"]["invented"] = json!(true);
    assert!(parse_provider_control_claim(&extra_key).is_err());

    with_policy["requestedDataPolicy"]["policySha256"] = json!(hash('a'));
    assert!(parse_provider_control_claim(&with_policy).is_err());
    Ok(())
}

#[test]
fn nullable_branch_fields_are_present_and_explicitly_null() -> Result<(), Failure> {
    let upgrade = claim("upgradeProviderModel");
    assert!(upgrade["requestedDataPolicy"].is_null());
    parse_provider_control_claim(&upgrade)?;

    let mut missing_policy = upgrade;
    let removed_policy = missing_policy
        .as_object_mut()
        .and_then(|claim| claim.remove("requestedDataPolicy"));
    assert_eq!(removed_policy, Some(Value::Null));
    assert!(parse_provider_control_claim(&missing_policy).is_err());

    let mut disabled_auto = claim("setModelAutoUpgrade");
    disabled_auto["autoUpgradeEnabled"] = json!(false);
    disabled_auto["autoUpgradeTrack"] = Value::Null;
    assert_eq!(
        parse_provider_control_claim(&disabled_auto)?.branch,
        ProviderControlBranch::AutoUpgrade {
            enabled: false,
            track: None,
        },
    );

    let removed_track = disabled_auto
        .as_object_mut()
        .and_then(|claim| claim.remove("autoUpgradeTrack"));
    assert_eq!(removed_track, Some(Value::Null));
    assert!(parse_provider_control_claim(&disabled_auto).is_err());
    Ok(())
}

#[test]
fn disable_and_auto_upgrade_have_no_relay_plan() -> Result<(), Failure> {
    for operation_id in ["disableProviderRouting", "setModelAutoUpgrade"] {
        let parsed = parse_provider_control_claim(&claim(operation_id))?;
        assert_eq!(parsed.branch.relay_model(), None);
    }
    for operation_id in ["testProviderConnection", "upgradeProviderModel"] {
        let parsed = parse_provider_control_claim(&claim(operation_id))?;
        assert!(parsed.branch.relay_model().is_some());
    }
    Ok(())
}

#[test]
fn provider_success_requires_every_actual_proof_digest() -> Result<(), Failure> {
    let proof = RelayConnectionProof {
        gateway_receipt_sha256: hash('a'),
        payload_sha256: hash('b'),
        provider_request_id_hash: hash('c'),
        usage: RelayUsage {
            input_units: 2,
            output_units: 1,
            cached_input_units: Some(0),
            billable_units: 3,
            evidence_sha256: hash('d'),
        },
    };
    provider_control_success_result(ProviderControlOperationId::TestProviderConnection, proof)?;

    let missing = RelayConnectionProof {
        gateway_receipt_sha256: String::new(),
        payload_sha256: hash('b'),
        provider_request_id_hash: hash('c'),
        usage: RelayUsage {
            input_units: 2,
            output_units: 1,
            cached_input_units: None,
            billable_units: 3,
            evidence_sha256: hash('d'),
        },
    };
    assert!(
        provider_control_success_result(ProviderControlOperationId::UpgradeProviderModel, missing,)
            .is_err()
    );

    let inconsistent_usage = RelayConnectionProof {
        gateway_receipt_sha256: hash('a'),
        payload_sha256: hash('b'),
        provider_request_id_hash: hash('c'),
        usage: RelayUsage {
            input_units: 2,
            output_units: 1,
            cached_input_units: None,
            billable_units: 99,
            evidence_sha256: hash('d'),
        },
    };
    assert!(
        provider_control_success_result(
            ProviderControlOperationId::TestProviderConnection,
            inconsistent_usage,
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn retryable_execution_becomes_terminal_when_the_job_budget_is_exhausted() {
    let failure = Failure::Retryable("PROVIDER_UNAVAILABLE", "redacted".to_owned());
    assert_eq!(
        provider_control_failure_disposition(&failure, 1, 8),
        ("PROVIDER_UNAVAILABLE", true),
    );
    assert_eq!(
        provider_control_failure_disposition(&failure, 8, 8),
        ("PROVIDER_UNAVAILABLE", false),
    );
}

#[test]
fn recorded_failure_terminalizes_the_delivery_without_losing_detail() {
    let retryable = Failure::Retryable("PROVIDER_UNAVAILABLE", "relay timeout".to_owned());
    assert_eq!(
        provider_control_failure_disposition(&retryable, 1, 8),
        ("PROVIDER_UNAVAILABLE", true),
    );
    let retryable = provider_control_delivery_terminal(retryable);
    assert!(matches!(
        retryable,
        Failure::Terminal("PROVIDER_UNAVAILABLE", detail) if detail == "relay timeout"
    ));

    let terminal = provider_control_delivery_terminal(Failure::Terminal(
        "PROVIDER_RESPONSE_INVALID",
        "usage".to_owned(),
    ));
    assert!(matches!(
        terminal,
        Failure::Terminal("PROVIDER_RESPONSE_INVALID", detail) if detail == "usage"
    ));
}
