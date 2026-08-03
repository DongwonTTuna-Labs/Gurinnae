#![allow(clippy::assertions_on_constants)]

use crate::runtime::*;
use uuid::Uuid;

fn binding() -> SnapshotBinding {
    SnapshotBinding {
        run_id: Uuid::new_v4(),
        input_snapshot_id: Uuid::new_v4(),
        input_snapshot_sha256: "a".repeat(64),
    }
}

#[test]
fn source_fetch_v2_is_flat_and_round_trips_without_enum_wrapper() {
    let binding = binding();
    let request = SourceFetchRequest {
        binding: binding.clone(),
        request_kind: SourceRequestKind::SearchPublicWeb,
        query: Some("구린네 예산".to_owned()),
        locale: Some("ko-KR".to_owned()),
        country: Some("KR".to_owned()),
        recency_days: Some(30),
        result_limit: Some(5),
        canonical_url: None,
    };
    let Some(wire) = request.to_v2().ok() else {
        assert!(false);
        return;
    };
    let Some(json) = serde_json::to_value(&wire).ok() else {
        assert!(false);
        return;
    };
    assert!(json.get("SearchPublicWeb").is_none());
    assert_eq!(
        json.get("requestKind").and_then(|v| v.as_str()),
        Some("SEARCH_PUBLIC_WEB")
    );
    let Some(decoded) = serde_json::from_value::<SourceFetchRequestV2>(json).ok() else {
        assert!(false);
        return;
    };
    assert_eq!(
        SourceFetchRequest::from_v2(decoded, binding).ok(),
        Some(request)
    );
}

#[test]
fn source_fetch_v2_rejects_policy_drift() {
    let binding = binding();
    let request = SourceFetchRequest {
        binding: binding.clone(),
        request_kind: SourceRequestKind::FetchUrl,
        query: None,
        locale: None,
        country: None,
        recency_days: None,
        result_limit: None,
        canonical_url: Some("https://example.com/report".to_owned()),
    };
    let Some(wire) = request.to_v2().ok() else {
        assert!(false);
        return;
    };
    let Some(mut json) = serde_json::to_value(wire).ok() else {
        assert!(false);
        return;
    };
    json["allowRedirects"] = serde_json::json!(true);
    let Some(decoded) = serde_json::from_value::<SourceFetchRequestV2>(json).ok() else {
        assert!(false);
        return;
    };
    assert_eq!(
        SourceFetchRequest::from_v2(decoded, binding),
        Err(RuntimeError::InvalidTransition)
    );
}

#[test]
fn source_fetch_v2_declares_authority_multimodal_media_contract() {
    let request = SourceFetchRequest {
        binding: binding(),
        request_kind: SourceRequestKind::FetchUrl,
        query: None,
        locale: None,
        country: None,
        recency_days: None,
        result_limit: None,
        canonical_url: Some("https://example.com/evidence.pdf".to_owned()),
    };
    let Some(wire) = request.to_v2().ok() else {
        assert!(false, "closed source-fetch policy");
        return;
    };
    let SourceFetchRequestV2::FetchUrl {
        expected_media_types,
        ..
    } = wire
    else {
        assert!(false, "expected FETCH_URL wire request");
        return;
    };
    assert!(
        expected_media_types
            .iter()
            .any(|value| value == "application/pdf")
    );
    assert!(
        expected_media_types
            .iter()
            .any(|value| value == "image/png")
    );
    assert!(
        expected_media_types
            .iter()
            .any(|value| value == "audio/wav")
    );
    assert!(
        expected_media_types
            .iter()
            .any(|value| value == "video/webm")
    );
}

struct WrongAdapter;
impl ToolAdapter for WrongAdapter {
    fn id(&self) -> ToolId {
        ToolId::EvidenceRead
    }
    fn dispatch(&self, _request: &ToolRequest) -> Result<ToolResponse, DispatchError> {
        Ok(ToolResponse::EvidenceSearch(EvidenceSearchResponse {
            query_digest: "b".repeat(64),
            hits: Vec::new(),
        }))
    }
}

#[test]
fn all_thirteen_tools_are_closed_and_cross_response_is_rejected() {
    assert_eq!(ToolId::ALL.len(), 13);
    assert_eq!(
        ToolId::ALL
            .iter()
            .map(|tool| tool.wire_name())
            .collect::<std::collections::BTreeSet<_>>(),
        std::collections::BTreeSet::from([
            "agency.profile",
            "claim.language_check",
            "contract.find_comparables",
            "contract.search",
            "entity.lookup",
            "evidence.read",
            "evidence.search",
            "relationship.neighbors",
            "response.read",
            "rule.reproduce",
            "source.fetch",
            "source.locator_verify",
            "supplier.profile",
        ])
    );
    let mut dispatcher = TypedDispatcher::new();
    dispatcher.register(WrongAdapter);
    let request = ToolRequest::EvidenceRead(EvidenceReadRequest {
        binding: binding(),
        evidence_id: Uuid::new_v4(),
    });
    assert_eq!(
        dispatcher.dispatch("investigator", &request),
        Err(DispatchError::ResponseTypeMismatch)
    );
    assert_eq!(
        dispatcher.dispatch(
            "citation-verifier",
            &ToolRequest::ResponseRead(ResponseReadRequest {
                binding: binding(),
                response_id: Uuid::new_v4()
            })
        ),
        Err(DispatchError::ToolDenied)
    );
    assert_eq!(
        dispatcher.dispatch(
            "skeptic",
            &ToolRequest::ContractSearch(ContractSearchRequest {
                binding: binding(),
                entity_kind: ContractEntityKind::Any,
                entity_id: None,
                from_date: None,
                to_date: None,
                procurement_methods: Vec::new(),
                limit: 10,
            })
        ),
        Err(DispatchError::ToolDenied)
    );
}

#[test]
fn transcript_requires_prior_digest_and_monotonic_turns() {
    let initial = "1".repeat(64);
    let mut transcript = match Transcript::new(initial) {
        Ok(value) => value,
        Err(error) => {
            assert!(false, "{error}");
            return;
        }
    };
    let turn = ProviderTurn {
        turn: 1,
        prior_transcript_sha256: transcript.digest.clone(),
        request_sha256: "2".repeat(64),
        idempotency_key: "idem-1".to_owned(),
        envelope: ProviderEnvelope::FinalOutput(AgentFinalOutput {
            status: FinalStatus::Abstained,
            summary: "bounded".to_owned(),
            citations: Vec::new(),
        }),
    };
    assert!(transcript.append(turn).is_ok());
    let duplicate = ProviderTurn {
        turn: 1,
        prior_transcript_sha256: transcript.digest.clone(),
        request_sha256: "3".repeat(64),
        idempotency_key: "idem-2".to_owned(),
        envelope: ProviderEnvelope::FinalOutput(AgentFinalOutput {
            status: FinalStatus::Abstained,
            summary: "duplicate".to_owned(),
            citations: Vec::new(),
        }),
    };
    assert_eq!(
        transcript.append(duplicate),
        Err(RuntimeError::TranscriptConflict)
    );
}

#[test]
fn cancellation_requires_reconciliation_after_possible_effect() {
    let mut control = RunControl::new(Uuid::new_v4());
    let queued = match control.cancel(1, CancelReason::UserRequest, "stop".to_owned()) {
        Ok(value) => value,
        Err(error) => {
            assert!(false, "{error}");
            return;
        }
    };
    assert_eq!(queued.next_status, RunStatus::Cancelled);
    assert_eq!(control.control_state, ControlState::Settled);
    let mut running = RunControl::new(Uuid::new_v4());
    running.status = RunStatus::Running;
    running.control_state = ControlState::Active;
    let requested = match running.cancel(1, CancelReason::CostStop, "budget".to_owned()) {
        Ok(value) => value,
        Err(error) => {
            assert!(false, "{error}");
            return;
        }
    };
    assert_eq!(requested.next_status, RunStatus::Running);
    assert_eq!(running.control_state, ControlState::CancelRequested);
    let proof = ReconciliationProof {
        kind: ProofKind::DefinitiveNoDispatch,
        accepted_effect: false,
        proof_sha256: "4".repeat(64),
    };
    let settled = match running.reconcile(2, proof) {
        Ok(value) => value,
        Err(error) => {
            assert!(false, "{error}");
            return;
        }
    };
    assert_eq!(settled.next_status, RunStatus::Cancelled);
    assert_eq!(running.control_state, ControlState::Settled);
}

struct FinalProvider;
impl ProviderAdapter for FinalProvider {
    fn complete(&self, request: &ProviderRequest) -> Result<ProviderReply, ProviderRuntimeError> {
        let envelope = ProviderEnvelope::FinalOutput(AgentFinalOutput {
            status: FinalStatus::Abstained,
            summary: "bounded abstention".to_owned(),
            citations: Vec::new(),
        });
        let mut receipt = ProviderReceipt {
            idempotency_key: request.idempotency_key.clone(),
            request_sha256: provider_request_sha256(request)
                .map_err(|_| ProviderRuntimeError::InvalidReceipt)?,
            outcome: ProviderOutcome::FinalAccepted,
            cost_micros_krw: 1,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 =
            provider_receipt_sha256(&receipt).map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        Ok(ProviderReply { envelope, receipt })
    }
}

struct ToolThenFinalProvider {
    binding: SnapshotBinding,
    evidence_id: Uuid,
}
impl ProviderAdapter for ToolThenFinalProvider {
    fn complete(&self, request: &ProviderRequest) -> Result<ProviderReply, ProviderRuntimeError> {
        let envelope = if request.prior_tool_result.is_none() {
            ProviderEnvelope::ToolCall(ToolCall {
                call_id: Uuid::new_v4(),
                request: ToolRequest::EvidenceRead(EvidenceReadRequest {
                    binding: self.binding.clone(),
                    evidence_id: self.evidence_id,
                }),
                request_wire: serde_json::json!({
                    "schemaVersion": "evidence.read.request.v2",
                    "evidenceId": self.evidence_id,
                }),
                request_sha256: "c".repeat(64),
            })
        } else {
            ProviderEnvelope::FinalOutput(AgentFinalOutput {
                status: FinalStatus::Completed,
                summary: "tool result consumed".to_owned(),
                citations: Vec::new(),
            })
        };
        let mut receipt = ProviderReceipt {
            idempotency_key: request.idempotency_key.clone(),
            request_sha256: provider_request_sha256(request)
                .map_err(|_| ProviderRuntimeError::InvalidReceipt)?,
            outcome: match envelope {
                ProviderEnvelope::ToolCall(_) => ProviderOutcome::ToolCallAccepted,
                ProviderEnvelope::FinalOutput(_) => ProviderOutcome::FinalAccepted,
            },
            cost_micros_krw: 1,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 =
            provider_receipt_sha256(&receipt).map_err(|_| ProviderRuntimeError::InvalidReceipt)?;
        Ok(ProviderReply { envelope, receipt })
    }
}

#[test]
fn bounded_runtime_accepts_one_typed_final_turn() {
    let runtime = MultiTurnRuntime {
        provider: FinalProvider,
        tools: TypedDispatcher::new(),
    };
    let result = runtime.run(
        "investigator",
        Uuid::new_v4(),
        "1".repeat(64),
        "2".repeat(64),
        MultiTurnConfig {
            max_provider_turns: 2,
            max_tool_calls: 1,
            budget_micros_krw: 10,
            worst_case_turn_cost_micros_krw: 1,
        },
    );
    assert!(matches!(result, Ok(RunOutcome::Abstained { .. })));
}

#[test]
fn bounded_runtime_passes_typed_tool_result_to_follow_up_turn() {
    let run_id = Uuid::new_v4();
    let binding = SnapshotBinding {
        run_id,
        input_snapshot_id: Uuid::new_v4(),
        input_snapshot_sha256: "a".repeat(64),
    };
    let evidence_id = Uuid::new_v4();
    let runtime = MultiTurnRuntime {
        provider: ToolThenFinalProvider {
            binding: binding.clone(),
            evidence_id,
        },
        tools: TypedDispatcher::from_snapshot(ToolSnapshot {
            binding,
            evidence: vec![EvidenceRecord {
                evidence_id,
                source_use_id: Uuid::new_v4(),
                source_use_sha256: "c".repeat(64),
                selected_content_sha256: "b".repeat(64),
                locator: "page:1".to_owned(),
            }],
            responses: Vec::new(),
            comparables: Vec::new(),
            entities: Vec::new(),
            rules: Vec::new(),
            contracts: Vec::new(),
            supplier_profiles: Vec::new(),
            agency_profiles: Vec::new(),
            relationships: Vec::new(),
            typed_relationships: Vec::new(),
            typed_relationship_query_digest: None,
            source_artifacts: Vec::new(),
        }),
    };
    let result = runtime.run(
        "investigator",
        run_id,
        "1".repeat(64),
        "2".repeat(64),
        MultiTurnConfig {
            max_provider_turns: 2,
            max_tool_calls: 1,
            budget_micros_krw: 10,
            worst_case_turn_cost_micros_krw: 1,
        },
    );
    assert!(matches!(result, Ok(RunOutcome::Succeeded { .. })));
    if let Ok(RunOutcome::Succeeded { transcript, .. }) = result {
        assert_eq!(transcript.turns.len(), 2);
    }
}

#[test]
fn worst_case_reservation_blocks_before_provider_dispatch() {
    let runtime = MultiTurnRuntime {
        provider: FinalProvider,
        tools: TypedDispatcher::new(),
    };
    let result = runtime.run(
        "investigator",
        Uuid::new_v4(),
        "1".repeat(64),
        "2".repeat(64),
        MultiTurnConfig {
            max_provider_turns: 1,
            max_tool_calls: 0,
            budget_micros_krw: 1,
            worst_case_turn_cost_micros_krw: 2,
        },
    );
    assert!(matches!(result, Ok(RunOutcome::BudgetBlocked { .. })));
}

#[test]
fn snapshot_dispatcher_registers_all_thirteen_typed_adapters() {
    let binding = binding();
    let evidence_id = Uuid::new_v4();
    let dispatcher = TypedDispatcher::from_snapshot(ToolSnapshot {
        binding: binding.clone(),
        evidence: vec![EvidenceRecord {
            evidence_id,
            source_use_id: Uuid::new_v4(),
            source_use_sha256: "c".repeat(64),
            selected_content_sha256: "b".repeat(64),
            locator: "page:1".to_owned(),
        }],
        responses: Vec::new(),
        comparables: Vec::new(),
        entities: Vec::new(),
        rules: Vec::new(),
        contracts: Vec::new(),
        supplier_profiles: Vec::new(),
        agency_profiles: Vec::new(),
        relationships: Vec::new(),
        typed_relationships: Vec::new(),
        typed_relationship_query_digest: None,
        source_artifacts: Vec::new(),
    });
    let request = ToolRequest::EvidenceRead(EvidenceReadRequest {
        binding,
        evidence_id,
    });
    assert!(matches!(
        dispatcher.dispatch("investigator", &request),
        Ok(ToolResponse::EvidenceRead(_))
    ));
    let denied = ToolRequest::EvidenceRead(EvidenceReadRequest {
        binding: SnapshotBinding {
            run_id: Uuid::new_v4(),
            input_snapshot_id: Uuid::new_v4(),
            input_snapshot_sha256: "a".repeat(64),
        },
        evidence_id,
    });
    assert_eq!(
        dispatcher.dispatch("investigator", &denied),
        Err(DispatchError::RequestInvalid)
    );
}

#[test]
fn investigator_source_fetch_is_fetch_url_only() {
    let binding = binding();
    let dispatcher = TypedDispatcher::from_snapshot(ToolSnapshot {
        binding: binding.clone(),
        evidence: Vec::new(),
        responses: Vec::new(),
        comparables: Vec::new(),
        entities: Vec::new(),
        rules: Vec::new(),
        contracts: Vec::new(),
        supplier_profiles: Vec::new(),
        agency_profiles: Vec::new(),
        relationships: Vec::new(),
        typed_relationships: Vec::new(),
        typed_relationship_query_digest: None,
        source_artifacts: Vec::new(),
    });
    let search_request = ToolRequest::SourceFetch(SourceFetchRequest {
        binding: binding.clone(),
        request_kind: SourceRequestKind::SearchPublicWeb,
        query: Some("공식 공개 출처".to_owned()),
        locale: Some("ko-KR".to_owned()),
        country: Some("KR".to_owned()),
        recency_days: Some(30),
        result_limit: Some(5),
        canonical_url: None,
    });
    assert!(matches!(
        dispatcher.dispatch("market-researcher", &search_request),
        Ok(ToolResponse::SourceFetch(_))
    ));
    for agent in [
        "investigator",
        "skeptic",
        "claim-drafter",
        "citation-verifier",
    ] {
        assert_eq!(
            dispatcher.dispatch(agent, &search_request),
            Err(DispatchError::ToolDenied),
            "{agent}"
        );
    }
    let fetch_request = ToolRequest::SourceFetch(SourceFetchRequest {
        binding,
        request_kind: SourceRequestKind::FetchUrl,
        query: None,
        locale: None,
        country: None,
        recency_days: None,
        result_limit: None,
        canonical_url: Some("https://official.example/notices/42".to_owned()),
    });
    assert_eq!(
        dispatcher.dispatch("investigator", &fetch_request),
        Err(DispatchError::RequestInvalid),
        "FETCH_URL passes the agent policy and reaches the empty snapshot adapter"
    );
}
