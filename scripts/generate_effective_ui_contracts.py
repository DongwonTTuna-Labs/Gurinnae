#!/usr/bin/env python3
"""Build the additive, source-derived UI execution contracts.

The tables in this module are intentionally explicit.  Screen meaning, special
state meaning, action placement, and journey edges must never be inferred from
keywords, catalog order, or a renderer fallback.
"""

from __future__ import annotations

import argparse
import copy
import re
import sys
from pathlib import Path
from typing import Any

import yaml

from journey_contracts import build_journey_contracts as build_canonical_journey_contracts


ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "specs" / "ui"
PRODUCT = ROOT / "specs" / "product"
API = ROOT / "specs" / "api"

TARGETS = {
    "effective": UI / "effective-screen-contracts.yaml",
    "actions": UI / "screen-action-contracts.yaml",
    "states": UI / "state-occurrence-contracts.yaml",
    "accessibility": UI / "accessibility-responsive-contracts.yaml",
    "journeys": UI / "journey-graph-contracts.yaml",
}


class StrictLoader(yaml.SafeLoader):
    """Reject duplicate mapping keys instead of silently accepting last-write-wins."""


def _construct_unique_mapping(
    loader: StrictLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    pairs = loader.construct_pairs(node, deep=deep)
    mapping: dict[Any, Any] = {}
    for key, value in pairs:
        if key in mapping:
            raise ValueError(f"duplicate YAML key: {key!r}")
        mapping[key] = value
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_mapping,
)


class NoAliasDumper(yaml.SafeDumper):
    def ignore_aliases(self, data: Any) -> bool:
        return True


def load_yaml(path: Path) -> dict[str, Any]:
    value = yaml.load(path.read_text(encoding="utf-8"), Loader=StrictLoader)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a YAML mapping")
    return value


def unique_by_key(
    rows: list[dict[str, Any]], key: str, source: str
) -> dict[str, dict[str, Any]]:
    values: dict[str, dict[str, Any]] = {}
    for row in rows:
        identifier = row.get(key)
        if not isinstance(identifier, str) or not identifier:
            raise ValueError(f"{source}: missing non-empty {key}")
        if identifier in values:
            raise ValueError(f"{source}: duplicate {key} {identifier}")
        values[identifier] = row
    return values


def parse_rows(raw: str, width: int) -> dict[str, tuple[str, ...]]:
    rows: dict[str, tuple[str, ...]] = {}
    for line in raw.strip().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = tuple(part.strip() for part in line.split("|"))
        if len(parts) != width:
            raise ValueError(f"invalid explicit row ({len(parts)} != {width}): {line}")
        key = parts[0]
        if key in rows:
            raise ValueError(f"duplicate explicit row: {key}")
        rows[key] = parts[1:]
    return rows


def parse_binding_list(raw: str) -> list[dict[str, str]]:
    """Parse an authored ``operation.path->viewModelField`` list."""

    bindings: list[dict[str, str]] = []
    for item in raw.split(","):
        source, separator, target = item.strip().partition("->")
        if separator != "->" or not source or not target:
            raise ValueError(f"invalid authored semantic binding: {item}")
        operation_id, dot, field_path = source.partition(".")
        if not dot or not operation_id or not field_path:
            raise ValueError(f"invalid authored operation source: {source}")
        bindings.append(
            {
                "operation_id": operation_id,
                "operation_field_path": field_path,
                "view_model_field": target,
            }
        )
    return bindings


# screen | object | state | answer | evidence | unknown/blocker | next action
SCREEN_SECTION_ROLES = parse_rows(
    r"""
PUB-001|mission|recent|mission|coverage|corrections|search
PUB-002|query|results|results|results|results|query
PUB-003|scope|results|results|scope|scope|filters
PUB-004|status|status|known|evidence|unknown|evidence
PUB-005|revision-banner|revision-banner|snapshot|citation|diff|revision-banner
PUB-006|summary|summary|formula|inputs|limitations|download
PUB-007|search|coverage|results|coverage|coverage|search
PUB-008|identity|coverage|metrics|methods|corrections|contracts
PUB-009|search|identity-note|results|identity-note|identity-note|search
PUB-010|identity|coverage|metrics|relationships|corrections|contracts
PUB-011|scope|results|results|scope|limitations|filters
PUB-012|identity|changes|terms|provenance|limitations|provenance
PUB-013|overview|changes|pipeline|quality|ai|rules
PUB-014|purpose|versions|calculation|evaluation|false-positive|evaluation
PUB-015|summary|latency|summary|sources|gaps|sources
PUB-016|status|status|quality|terms|quality|list
PUB-017|identity|freshness|coverage|schema|terms|impact
PUB-018|principle|records|records|feed|principle|filters
PUB-019|target|status|before-after|review|reason|target
PUB-020|datasets|snapshots|datasets|license|limits|datasets
PUB-021|getting-started|versioning|resources|download|errors|getting-started
PUB-022|mission|process|mission|process|non-goals|contact
PUB-023|principles|income|income|reports|conflicts|reports
PUB-024|structure|oversight|independence|records|conflicts|appeal
PUB-025|states|history|publication-gate|history|privacy|correction
PUB-026|routing|channels|routing|security|routing|form
PUB-027|intro|review|target|evidence|privacy|review
PUB-028|receipt|receipt|summary|receipt|next|manage
PUB-029|topic|events|topic|privacy|privacy|email
PUB-030|identity|delivery|preferences|delivery|delivery|preferences
PUB-031|controller|history|rights|security|retention|rights
PUB-032|service|changes|content|data|liability|data
PUB-033|commitment|conformance|commitment|roadmap|limitations|contact
PUB-034|message|impact|message|reference|impact|actions
RSP-001|identity|verification|process|security|deadline|verification
RSP-002|questions|deadline|questions|references|public-use|questions
RSP-003|progress|save|questions|statement|consent|save
RSP-004|guidance|scan|files|metadata|scan|files
RSP-005|answers|consequence|answers|attachments|consent|consequence
RSP-006|receipt|receipt|summary|receipt|next|next
RSP-007|current|review|request|current|partial|review
RSP-008|status|status|impact|security|impact|actions
AUTH-001|environment|environment|signin|support|support|signin
AUTH-002|reason|reason|methods|recovery|reason|methods
AUTH-003|message|message|message|reference|message|actions
AUTH-004|status|status|draft|support|draft|signin
INT-001|critical|incidents|my-work|critical|cost|my-work
INT-002|views|handoff|tasks|handoff|handoff|tasks
INT-003|query|results|results|recent|results|query
INT-004|filters|notifications|notifications|notifications|preferences|notifications
SIG-001|scope|table|table|scope|table|table
SIG-002|identity|quality|calculation|provenance|cohort|decision
CAS-001|views|table|table|assignment|filters|table
CAS-002|header|readiness|known-unknown|activity|known-unknown|next
CAS-003|summary|relationships|signals|relationships|relationships|signals
CAS-004|matrix|gaps|list|matrix|gaps|list
CAS-005|source|verification|content|locator|access|verification
CAS-006|summary|lint|claims|relationships|lint|editor
CAS-007|board|matrix|board|matrix|questions|board
CAS-008|requests|verification|submissions|timeline|verification|public-copy
CAS-009|target|gate|questions|preview|disclosure|gate
CAS-010|runs|budget|suggestions|runs|budget|runs
CAS-011|identity|safety|output|citations|safety|decisions
CAS-012|filters|timeline|timeline|related|public-view|timeline
CAS-013|summary|gates|summary|reviews|gates|tasks
CAS-014|watermark|checks|render|diff|checks|checks
CAS-015|history|reviews|proposal|impact|reviews|proposal
CAS-016|scope|events|events|exports|events|events
REV-001|views|independence|queue|independence|independence|queue
REV-002|identity|risks|matrix|preview|risks|decision
REV-003|target|gates|impact|gates|gates|reauth
COR-001|urgent|requests|requests|requests|urgent|requests
COR-002|request|review|investigation|original|impact|review
SRC-001|ownership|health|registry|impact|health|registry
SRC-002|identity|status|quality|schema|downstream|runbook
SRC-003|summary|runs|runs|schedule|runs|runs
SRC-004|identity|counts|errors|artifacts|impact|actions
SRC-005|alert|decision|diff|samples|impact|decision
SRC-006|scope|progress|estimate|dedupe|safety|approval
RULE-001|status|status|registry|changes|changes|registry
RULE-002|identity|approval|definition|usage|blockers|approval
RULE-003|dataset|signoff|metrics|errors|limitations|signoff
RULE-004|target|gates|impact|rollback|gates|approval
OPS-001|services|incidents|slo|security|incidents|incidents
OPS-002|summary|jobs|jobs|runbook|jobs|jobs
OPS-003|identity|state|effects|audit|effects|recovery
OPS-004|envelope|spend|forecast|changes|alerts|limits
OPS-005|status|status|latency|privacy|incidents|status
OPS-006|active|active|impact|history|approval|approval
AUD-001|query|integrity|events|integrity|events|events
ADM-001|summary|review|users|review|requests|review
ADM-002|identity|conflicts|roles|activity|conflicts|requests
ADM-003|catalog|review|capabilities|history|conflicts|review
ACC-001|identity|security|sessions|security|access-request|sessions
""",
    7,
)


# screen | object | state | answer | evidence | unknown | next action
#
# This is a deliberately authored registry.  ``$projection`` means the BFF/API
# projection is required but is not present in the current runtime contract; it
# is never treated as implemented.  Keeping the mapping here makes removal of a
# semantic field fail set equality instead of silently selecting another DTO
# field.
SCREEN_SEMANTIC_BINDING_ROWS = parse_rows(
    r"""
PUB-001|listPublicCases.$projection.mission_object->mission_object|listPublicCases.$projection.recent_state->recent_state|listPublicCases.$projection.mission_answer->mission_answer|listPublicCases.$projection.coverage_evidence->coverage_evidence|listPublicCases.$projection.corrections_unknown->corrections_unknown|listPublicCases.$projection.search_next_action->search_next_action
PUB-002|searchPublicRecords.$projection.query_object->query_object,searchPublicRecords.appliedFilters->types_applied_filters|searchPublicRecords.$projection.results_state->results_state|searchPublicRecords.$projection.results_answer->results_answer|searchPublicRecords.$projection.coverage_evidence->coverage_evidence|searchPublicRecords.$projection.coverage_unknown->coverage_unknown|searchPublicRecords.$projection.query_next_action->query_next_action
PUB-003|listPublicCases.$projection.scope_object->scope_object|listPublicCases.$projection.results_state->results_state|listPublicCases.$projection.results_answer->results_answer|listPublicCases.$projection.scope_evidence->scope_evidence|listPublicCases.$projection.scope_unknown->scope_unknown|listPublicCases.$projection.filters_next_action->filters_next_action
PUB-004|getPublicCase.slug->case_slug,getPublicCase.title->case_title|getPublicCase.publicState->public_state,getPublicCase.revision->revision,getPublicCase.freshness->freshness|getPublicCase.confirmedFacts->confirmed_facts,getPublicCase.summary->answer_first_summary|getPublicCase.evidence->evidence_items,getPublicCase.timeline->evidence_timeline|getPublicCase.criticalUnknowns->material_unknowns,getPublicCase.counterEvidence->counter_evidence,getPublicCase.limitations->limitations|getCaseReproducibility.caseSlug->reproduction_case_slug,getCaseReproducibility.ruleId->reproduction_rule_id
PUB-005|getPublicCaseRevision.slug->case_slug,getPublicCaseRevision.revision->revision|getPublicCaseRevision.isLatest->is_latest,getPublicCaseRevision.supersededByRevision->superseded_by_revision|getPublicCaseRevision.content->fixed_content,getPublicCaseRevision.diffFromPrevious->diff_from_previous|getPublicCaseRevision.snapshotHash->snapshot_hash,getPublicCaseRevision.publishedAt->published_at|getPublicCaseRevision.diffFromPrevious->material_changes|listCaseRevisions.items->available_revisions
PUB-006|getCaseReproducibility.caseSlug->case_slug,getCaseReproducibility.ruleId->rule_id,getCaseReproducibility.ruleVersion->rule_version|getCaseReproducibility.inputDigest->input_digest,getCaseReproducibility.resultDigest->result_digest|getCaseReproducibility.formula->formula,getCaseReproducibility.roundingPolicy->rounding_policy,getCaseReproducibility.result->result|getCaseReproducibility.includedCohort->included_cohort,getCaseReproducibility.excludedCohort->excluded_cohort|getCaseReproducibility.limitations->limitations|getCaseReproducibility.$projection.download_metadata->download_metadata
PUB-007|listAgencies.$projection.search_object->search_object,listAgencies.appliedFilters->agency_filters|listAgencies.$projection.coverage_state->coverage_state|listAgencies.$projection.results_answer->results_answer|listAgencies.$projection.coverage_evidence->coverage_evidence|listAgencies.$projection.coverage_unknown->coverage_unknown|listAgencies.$projection.search_next_action->search_next_action
PUB-008|getAgency.id->agency_id,getAgency.name->agency_name|getAgency.freshness->freshness|getAgency.metrics->metrics,getAgency.coverage->coverage|getAgency.identifiers->official_identifiers,getAgency.recentContracts->recent_contracts|getAgency.identityWarnings->identity_warnings|getAgency.recentCases->recent_cases
PUB-009|listSuppliers.$projection.search_object->search_object,listSuppliers.appliedFilters->supplier_filters|listSuppliers.$projection.identity_note_state->identity_note_state|listSuppliers.$projection.results_answer->results_answer|listSuppliers.$projection.identity_note_evidence->identity_note_evidence|listSuppliers.$projection.identity_note_unknown->identity_note_unknown|listSuppliers.$projection.search_next_action->search_next_action
PUB-010|getSupplier.id->supplier_id,getSupplier.name->supplier_name|getSupplier.freshness->freshness|getSupplier.metrics->metrics,getSupplier.coverage->coverage|getSupplier.identifiers->official_identifiers,getSupplier.recentContracts->recent_contracts|getSupplier.identityWarnings->identity_warnings|getSupplier.recentCases->recent_cases
PUB-011|listContracts.$projection.scope_object->scope_object|listContracts.$projection.results_state->results_state|listContracts.$projection.results_answer->results_answer|listContracts.$projection.scope_evidence->scope_evidence|listContracts.$projection.limitations_unknown->limitations_unknown|listContracts.$projection.filters_next_action->filters_next_action
PUB-012|getContract.id->contract_id,getContract.contractNumber->contract_number|getContract.status->contract_status,getContract.changes->changes|getContract.title->title,getContract.currentAmount->current_amount,getContract.lineItems->line_items,getContract.contractMethod->procurement_method|getContract.sourceDocuments->source_documents|getContract.normalizationWarnings->normalization_warnings|getContract.relatedCases->related_cases
PUB-013|listRules.$projection.overview_object->overview_object|listRules.$projection.changes_state->changes_state|getMethodologyOverview.summary->methodology_summary|getMethodologyOverview.links->methodology_sources|getMethodologyOverview.$projection.ai_limitations->ai_limitations|listRules.$projection.rules_next_action->rules_next_action
PUB-014|getRule.id->rule_id,getRule.version->rule_version|getRule.status->rule_status,getRule.updatedAt->updated_at|getRule.summary->rule_summary,getRule.data->calculation_contract|getRule.links->evaluation_links|getRule.data->false_positive_and_limitations|listRuleCases.items->related_cases
PUB-015|getCoverage.asOf->coverage_as_of|getCoverage.dateRange->covered_date_range,getCoverage.methodologyVersion->methodology_version|getCoverage.recordCounts->record_counts,getCoverage.sources->sources|getCoverage.sources->source_evidence|getCoverage.knownGaps->known_gaps|listSourceStatus.items->source_status_actions
PUB-016|listSourceStatus.$projection.status_object->status_object|listSourceStatus.$projection.status_state->status_state|listSourceStatus.$projection.quality_answer->quality_answer|listSourceStatus.$projection.terms_evidence->terms_evidence|listSourceStatus.$projection.quality_unknown->quality_unknown|listSourceStatus.$projection.list_next_action->list_next_action
PUB-017|getSource.id->source_id,getSource.title->source_title|getSource.status->source_status,getSource.updatedAt->updated_at|getSource.summary->coverage_summary,getSource.data->schema_and_quality|getSource.links->official_and_terms_links|getSource.data->known_limitations|getSource.links->operational_links
PUB-018|listCorrections.$projection.principle_object->principle_object|listCorrections.$projection.records_state->records_state|listCorrections.$projection.records_answer->records_answer|listCorrections.$projection.feed_evidence->feed_evidence|listCorrections.$projection.principle_unknown->principle_unknown|listCorrections.$projection.filters_next_action->filters_next_action
PUB-019|getCorrection.id->correction_id,getCorrection.title->correction_title|getCorrection.status->correction_status,getCorrection.version->correction_version|getCorrection.summary->before_after_summary,getCorrection.data->impact|getCorrection.links->review_records|getCorrection.data->reason_and_limitations|getCorrection.links->target_route
PUB-020|listPublicDatasets.$projection.datasets_object->datasets_object|listPublicDatasets.$projection.snapshots_state->snapshots_state|listPublicDatasets.$projection.datasets_answer->datasets_answer|listPublicDatasets.$projection.license_evidence->license_evidence|listPublicDatasets.$projection.limits_unknown->limits_unknown|listPublicDatasets.$projection.datasets_next_action->datasets_next_action
PUB-021|getPublicApiDocumentation.id->documentation_id,getPublicApiDocumentation.version->api_version|getPublicApiDocumentation.status->documentation_status,getPublicApiDocumentation.updatedAt->updated_at|getPublicApiDocumentation.summary->resource_summary,getPublicApiDocumentation.data->endpoint_contracts|getPublicApiDocumentation.links->schema_and_openapi_links|getPublicApiDocumentation.data->errors_and_limits|downloadPublicOpenApi.binary->openapi_download
PUB-022|getAboutContent.id->about_revision,getAboutContent.title->service_name|getAboutContent.status->content_status,getAboutContent.updatedAt->updated_at|getAboutContent.summary->mission,getAboutContent.data->process|getAboutContent.links->operating_records|getAboutContent.data->non_goals|getAboutContent.links->contact_and_governance
PUB-023|getFundingContent.id->funding_revision,getFundingContent.title->funding_report_title|getFundingContent.status->report_status,getFundingContent.updatedAt->updated_at|getFundingContent.summary->income_and_cost_summary,getFundingContent.data->income_and_cost_detail|getFundingContent.links->audited_reports|getFundingContent.data->conflicts_and_concentration|listTransparencyReports.items->downloadable_reports
PUB-024|getGovernanceContent.id->governance_revision,getGovernanceContent.title->governance_title|getGovernanceContent.status->policy_status,getGovernanceContent.updatedAt->updated_at|getGovernanceContent.summary->governance_summary,getGovernanceContent.data->independence_structure|getGovernanceContent.links->oversight_records|getGovernanceContent.data->conflicts_and_limitations|getGovernanceContent.links->appeal_and_policy_routes
PUB-025|getEditorialPolicy.id->policy_revision,getEditorialPolicy.title->policy_title|getEditorialPolicy.status->policy_status,getEditorialPolicy.updatedAt->updated_at|getEditorialPolicy.summary->publication_policy,getEditorialPolicy.data->state_and_gate_rules|getEditorialPolicy.links->policy_history|getEditorialPolicy.data->privacy_and_response_limits|getEditorialPolicy.links->correction_route
PUB-026|getContactContent.id->contact_policy_revision,getContactContent.title->contact_title|getContactContent.status->channel_status,getContactContent.updatedAt->updated_at|getContactContent.summary->routing_guidance,getContactContent.data->channel_requirements|getContactContent.links->security_and_support|getContactContent.data->privacy_limits|getContactContent.links->contact_form_route
PUB-027|getCorrectionRequestDraftPreview.draft->safe_draft_identity|getCorrectionRequestDraftPreview.submissionDigest->submission_digest|getCorrectionRequestDraftPreview.draft->review_summary|getCorrectionRequestDraftPreview.attachments->verified_attachments|getCorrectionRequestDraftPreview.warnings->blocking_warnings|getCorrectionRequestDraftPreview.submissionDigest->next_submission_digest
PUB-028|getCorrectionReceipt.id->receipt_id,getCorrectionReceipt.title->receipt_title|getCorrectionReceipt.status->receipt_status,getCorrectionReceipt.version->receipt_version|getCorrectionReceipt.summary->submitted_scope,getCorrectionReceipt.data->submitted_items|getCorrectionReceipt.links->receipt_records|getCorrectionReceipt.data->next_step_uncertainty|getCorrectionReceipt.links->management_routes
PUB-029|createSubscription.requestId->request_id,createSubscription.aggregateId->subscription_id|createSubscription.status->subscription_status,createSubscription.verificationDispatched->verification_dispatched|createSubscription.aggregateId->selected_topic,createSubscription.acceptedAt->accepted_at|createSubscription.auditEventId->audit_event_id|createSubscription.$projection.verification_delivery_unknowns->verification_delivery_unknowns|createSubscription.links->verification_route
PUB-030|getSubscription.id->subscription_id,getSubscription.title->subscription_title|getSubscription.status->subscription_status,getSubscription.version->subscription_version|getSubscription.summary->preferences_summary,getSubscription.data->delivery_preferences|getSubscription.links->delivery_receipts|getSubscription.data->delivery_unknowns|getSubscription.links->preference_actions
PUB-031|getPrivacyPolicy.id->policy_revision,getPrivacyPolicy.title->controller_name|getPrivacyPolicy.status->policy_status,getPrivacyPolicy.updatedAt->updated_at|getPrivacyPolicy.summary->rights_summary,getPrivacyPolicy.data->processing_contract|getPrivacyPolicy.links->security_and_processor_records|getPrivacyPolicy.data->retention_and_limitations|getPrivacyPolicy.links->rights_request_route
PUB-032|getTerms.id->terms_revision,getTerms.title->terms_title|getTerms.status->terms_status,getTerms.updatedAt->updated_at|getTerms.summary->service_terms,getTerms.data->content_and_data_terms|getTerms.links->supporting_policies|getTerms.data->liability_and_prohibitions|getTerms.links->data_route
PUB-033|getAccessibilityStatement.id->statement_revision,getAccessibilityStatement.title->statement_title|getAccessibilityStatement.status->conformance_status,getAccessibilityStatement.updatedAt->updated_at|getAccessibilityStatement.summary->commitment,getAccessibilityStatement.data->conformance_detail|getAccessibilityStatement.links->audit_and_roadmap|getAccessibilityStatement.data->known_limitations|getAccessibilityStatement.links->support_route
PUB-034|getPublicSystemStatus.status->system_status,getPublicSystemStatus.asOf->as_of|getPublicSystemStatus.affectedCapabilities->affected_capabilities|getPublicSystemStatus.publicMessage->answer_first_message|getPublicSystemStatus.sourceStatus->status_evidence|getPublicSystemStatus.affectedCapabilities->unknown_impact|getPublicSystemStatus.$projection.safe_actions->safe_actions
RSP-001|getResponseAccessStatus.id->request_reference,getResponseAccessStatus.title->request_title|getResponseAccessStatus.status->access_status,getResponseAccessStatus.version->access_version|getResponseAccessStatus.summary->request_process,getResponseAccessStatus.data->deadline_and_sender|getResponseAccessStatus.links->security_support|getResponseAccessStatus.data->access_unknowns|getResponseAccessStatus.links->verification_action
RSP-002|getResponseRequest.requestId->request_id,getResponseRequest.partyName->party_name|getResponseRequest.status->request_status,getResponseRequest.dueAt->due_at|getResponseRequest.questions->questions,getResponseRequest.publicationScope->publication_scope|getResponseRequest.attachmentsPolicy->attachment_policy,getResponseRequest.contact->verified_contact|getResponseRequest.publicationScope->publication_uncertainty|getResponseRequest.contact->support_action
RSP-003|getResponseDraft.requestId->request_id,getResponseDraft.version->draft_version|getResponseDraft.savedAt->saved_at,getResponseDraft.expiresAt->expires_at|getResponseDraft.answers->answers|getResponseDraft.attachments->attachments,getResponseDraft.publicationConsent->consent_evidence|getResponseDraft.$projection.validation_unknowns->validation_unknowns|getResponseDraft.$projection.save_action->save_action
RSP-004|createResponseAttachmentUpload.requestId->request_id,createResponseAttachmentUpload.aggregateId->upload_id|createResponseAttachmentUpload.status->upload_status,createResponseAttachmentUpload.aggregateVersion->upload_version|createResponseAttachmentUpload.links->upload_guidance|finalizeResponseAttachment.auditEventId->scan_receipt|finalizeResponseAttachment.$projection.scan_unknowns->scan_unknowns|finalizeResponseAttachment.links->file_actions
RSP-005|getResponseSubmissionPreview.request->request_summary,getResponseSubmissionPreview.submissionDigest->submission_digest|getResponseSubmissionPreview.warnings->blocking_state|getResponseSubmissionPreview.answers->answers|getResponseSubmissionPreview.attachments->attachments,getResponseSubmissionPreview.publicationConsent->publication_consent|getResponseSubmissionPreview.warnings->material_unknowns|submitResponse.$projection.safe_receipt_identity->receipt_identity
RSP-006|getResponseReceipt.id->receipt_id,getResponseReceipt.title->receipt_title|getResponseReceipt.status->receipt_status,getResponseReceipt.version->receipt_version|getResponseReceipt.summary->submission_summary,getResponseReceipt.data->submitted_items|getResponseReceipt.links->receipt_and_status_links|getResponseReceipt.data->next_step_unknowns|getResponseReceipt.links->appeal_and_download_actions
RSP-007|requestResponseExtension.requestId->request_id,requestResponseExtension.aggregateId->extension_id|requestResponseExtension.status->extension_status,requestResponseExtension.aggregateVersion->extension_version|requestResponseExtension.acceptedAt->requested_at|requestResponseExtension.auditEventId->request_receipt|requestResponseExtension.$projection.partial_answer_unknowns->partial_answer_unknowns|requestResponseExtension.links->status_action
RSP-008|getResponseAccessStatus.id->safe_request_reference|getResponseAccessStatus.status->access_status,getResponseAccessStatus.version->status_version|getResponseAccessStatus.summary->impact_summary|getResponseAccessStatus.links->support_reference|getResponseAccessStatus.data->non_disclosing_reason|getResponseAccessStatus.links->safe_actions
AUTH-001|startOidcLogin.id->login_attempt_id,startOidcLogin.title->identity_provider_label|startOidcLogin.status->login_status,startOidcLogin.updatedAt->updated_at|startOidcLogin.summary->sign_in_guidance|startOidcLogin.links->support_links|startOidcLogin.data->environment_limitations|startOidcLogin.links->sign_in_action
AUTH-002|startStepUpAuthentication.$projection.action_context->action_context|startStepUpAuthentication.$projection.challenge_state->challenge_state|startStepUpAuthentication.$projection.available_methods->available_methods|startStepUpAuthentication.$projection.recovery_receipt->recovery_receipt|startStepUpAuthentication.$projection.method_unknowns->method_unknowns|startStepUpAuthentication.$projection.verify_action->verify_action
AUTH-003|getCurrentUserCapabilities.id->actor_id,getCurrentUserCapabilities.title->access_context|getCurrentUserCapabilities.status->access_status,getCurrentUserCapabilities.version->policy_version|getCurrentUserCapabilities.summary->denial_category|getCurrentUserCapabilities.links->policy_reference|getCurrentUserCapabilities.data->safe_reason_scope|getCurrentUserCapabilities.links->access_request_action
AUTH-004|startOidcLogin.id->reauth_attempt_id,startOidcLogin.title->session_context|startOidcLogin.status->reauth_status,startOidcLogin.updatedAt->updated_at|startOidcLogin.summary->draft_preservation_summary|startOidcLogin.links->support_reference|startOidcLogin.data->draft_unknowns|startOidcLogin.links->sign_in_action
INT-001|getInternalDashboard.myTasks->task_scope|getInternalDashboard.incidents->incident_state,getInternalDashboard.jobHealth->job_health|getInternalDashboard.myTasks->highest_value_work,getInternalDashboard.overdueTasks->overdue_work|getInternalDashboard.sourceHealth->source_evidence,getInternalDashboard.jobHealth->job_evidence|getInternalDashboard.budget->cost_risk,getInternalDashboard.notifications->unread_unknowns|getInternalDashboard.myTasks->task_actions
INT-002|listMyTasks.$projection.views_object->views_object|listMyTasks.$projection.handoff_state->handoff_state|listMyTasks.$projection.tasks_answer->tasks_answer|listMyTasks.$projection.handoff_evidence->handoff_evidence|listMyTasks.$projection.handoff_unknown->handoff_unknown|listMyTasks.$projection.tasks_next_action->tasks_next_action
INT-003|searchInternalRecords.$projection.query_object->query_object|searchInternalRecords.$projection.results_state->results_state|searchInternalRecords.$projection.results_answer->results_answer|searchInternalRecords.$projection.recent_evidence->recent_evidence|searchInternalRecords.$projection.results_unknown->results_unknown|searchInternalRecords.$projection.query_next_action->query_next_action
INT-004|listInternalNotifications.$projection.filters_object->filters_object|listInternalNotifications.$projection.notifications_state->notifications_state|listInternalNotifications.$projection.notifications_answer->notifications_answer|listInternalNotifications.$projection.notifications_evidence->notifications_evidence|listInternalNotifications.$projection.preferences_unknown->preferences_unknown|listInternalNotifications.$projection.notifications_next_action->notifications_next_action
SIG-001|listSignals.$projection.scope_object->scope_object|listSignals.$projection.table_state->table_state|listSignals.$projection.table_answer->table_answer|listSignals.$projection.scope_evidence->scope_evidence|listSignals.$projection.table_unknown->table_unknown|listSignals.$projection.table_next_action->table_next_action
SIG-002|getSignalTriageView.signal->signal_identity|getSignalTriageView.dataQuality->quality_state|getSignalTriageView.triggerExplanation->calculation_answer,getSignalTriageView.comparison->comparison|getSignalTriageView.triggerExplanation->calculation_evidence,getSignalTriageView.auditSummary->audit_evidence|getSignalTriageView.duplicates->duplicate_unknowns,getSignalTriageView.dataQuality->quality_unknowns|getSignalTriageView.$projection.triage_action->triage_action
CAS-001|listInternalCases.$projection.views_object->views_object|listInternalCases.$projection.table_state->table_state|listInternalCases.$projection.table_answer->table_answer|listInternalCases.$projection.assignment_evidence->assignment_evidence|listInternalCases.$projection.filters_unknown->filters_unknown|listInternalCases.$projection.table_next_action->table_next_action
CAS-002|getInternalCase.id->case_id,getInternalCase.title->case_title|getInternalCase.status->case_status,getInternalCase.version->case_version|getInternalCase.summary->answer_first_summary,getInternalCase.data->readiness|getInternalCase.links->activity_and_evidence|getInternalCase.data->known_unknowns|getInternalCase.links->next_case_tasks
CAS-003|listCaseSignals.$projection.summary_object->summary_object|listCaseSignals.$projection.relationships_state->relationships_state|listCaseSignals.$projection.signals_answer->signals_answer|listCaseSignals.$projection.relationships_evidence->relationships_evidence|listCaseSignals.$projection.relationships_unknown->relationships_unknown|listCaseSignals.$projection.signals_next_action->signals_next_action
CAS-004|listCaseEvidence.$projection.matrix_object->matrix_object|listCaseEvidence.$projection.gaps_state->gaps_state|listCaseEvidence.$projection.list_answer->list_answer|listCaseEvidence.$projection.matrix_evidence->matrix_evidence|listCaseEvidence.$projection.gaps_unknown->gaps_unknown|listCaseEvidence.$projection.list_next_action->list_next_action
CAS-005|getEvidenceWorkspace.evidence->evidence_identity|getEvidenceWorkspace.verification->verification_state|getEvidenceWorkspace.evidence->evidence_content,getEvidenceWorkspace.sourceContext->source_context|getEvidenceWorkspace.provenance->provenance,getEvidenceWorkspace.verification->verification_evidence|getEvidenceWorkspace.blockers->access_unknowns,getEvidenceWorkspace.redactions->redaction_unknowns|getEvidenceWorkspace.verification->verification_actions
CAS-006|listCaseClaims.$projection.summary_object->summary_object|listCaseClaims.$projection.lint_state->lint_state|listCaseClaims.$projection.claims_answer->claims_answer|listCaseClaims.$projection.relationships_evidence->relationships_evidence|listCaseClaims.$projection.lint_unknown->lint_unknown|listCaseClaims.$projection.editor_next_action->editor_next_action
CAS-007|listCaseHypotheses.$projection.board_object->board_object|listCaseHypotheses.$projection.matrix_state->matrix_state|listCaseHypotheses.$projection.board_answer->board_answer|listCaseHypotheses.$projection.matrix_evidence->matrix_evidence|listCaseHypotheses.$projection.questions_unknown->questions_unknown|listCaseHypotheses.$projection.board_next_action->board_next_action
CAS-008|listCaseResponses.$projection.requests_object->requests_object|listCaseResponses.$projection.verification_state->verification_state|listCaseResponses.$projection.submissions_answer->submissions_answer|listCaseResponses.$projection.timeline_evidence->timeline_evidence|listCaseResponses.$projection.verification_unknown->verification_unknown|listCaseResponses.$projection.public_copy_next_action->public_copy_next_action
CAS-009|getResponseRequestComposer.id->composer_id,getResponseRequestComposer.version->composer_version|getResponseRequestComposer.status->composer_status,getResponseRequestComposer.updatedAt->updated_at|getResponseRequestComposer.summary->questions_and_target,getResponseRequestComposer.data->preview|getResponseRequestComposer.links->source_and_policy_evidence|getResponseRequestComposer.data->disclosure_unknowns|getResponseRequestComposer.links->review_action
CAS-010|listCaseAgentRuns.$projection.runs_object->runs_object|listCaseAgentRuns.$projection.budget_state->budget_state|listCaseAgentRuns.$projection.suggestions_answer->suggestions_answer|listCaseAgentRuns.$projection.runs_evidence->runs_evidence|listCaseAgentRuns.$projection.budget_unknown->budget_unknown|listCaseAgentRuns.$projection.runs_next_action->runs_next_action
CAS-011|getAgentRun.id->run_id,getAgentRun.version->run_version|getAgentRun.status->run_status,getAgentRun.updatedAt->updated_at|getAgentRun.$projection.typed_findings->typed_findings,getAgentRun.$projection.proposals->proposals|getAgentRun.$projection.verified_citations->verified_citations,getAgentRun.$projection.tool_receipts->tool_receipts|getAgentRun.$projection.counter_evidence->counter_evidence,getAgentRun.$projection.unknowns->unknowns|getAgentRun.$projection.proposal_actions->proposal_actions
CAS-012|listCaseTimeline.$projection.filters_object->filters_object|listCaseTimeline.$projection.timeline_state->timeline_state|listCaseTimeline.$projection.timeline_answer->timeline_answer|listCaseTimeline.$projection.related_evidence->related_evidence|listCaseTimeline.$projection.public_view_unknown->public_view_unknown|listCaseTimeline.$projection.timeline_next_action->timeline_next_action
CAS-013|getReviewReadiness.id->case_id,getReviewReadiness.version->case_version|getReviewReadiness.status->readiness_status,getReviewReadiness.updatedAt->evaluated_at|getReviewReadiness.summary->readiness_summary,getReviewReadiness.data->gate_results|getReviewReadiness.links->review_evidence|getReviewReadiness.data->blocking_gaps|getReviewReadiness.links->blocker_actions
CAS-014|getPublicationPreview.snapshotId->snapshot_id,getPublicationPreview.previewHash->preview_hash|getPublicationPreview.validation->validation_state,getPublicationPreview.expiresAt->expires_at|getPublicationPreview.publicPayload->public_render,getPublicationPreview.renderedRoutes->rendered_routes|getPublicationPreview.previewHash->render_digest,getPublicationPreview.validation->validation_evidence|getPublicationPreview.validation->blocking_checks|getPublicationPreview.renderedRoutes->refresh_and_review_actions
CAS-015|listCaseCorrections.$projection.history_object->history_object|listCaseCorrections.$projection.reviews_state->reviews_state|listCaseCorrections.$projection.proposal_answer->proposal_answer|listCaseCorrections.$projection.impact_evidence->impact_evidence|listCaseCorrections.$projection.reviews_unknown->reviews_unknown|listCaseCorrections.$projection.proposal_next_action->proposal_next_action
CAS-016|listCaseAuditEvents.$projection.scope_object->scope_object|listCaseAuditEvents.$projection.events_state->events_state|listCaseAuditEvents.$projection.events_answer->events_answer|listCaseAuditEvents.$projection.exports_evidence->exports_evidence|listCaseAuditEvents.$projection.events_unknown->events_unknown|listCaseAuditEvents.$projection.events_next_action->events_next_action
REV-001|listReviewQueue.$projection.views_object->views_object|listReviewQueue.$projection.independence_state->independence_state|listReviewQueue.$projection.queue_answer->queue_answer|listReviewQueue.$projection.independence_evidence->independence_evidence|listReviewQueue.$projection.independence_unknown->independence_unknown|listReviewQueue.$projection.queue_next_action->queue_next_action
REV-002|getReviewSnapshot.snapshotId->snapshot_id,getReviewSnapshot.snapshotHash->snapshot_hash|getReviewSnapshot.caseVersion->case_version,getReviewSnapshot.unresolvedBlockers->blocking_state|getReviewSnapshot.claims->claims,getReviewSnapshot.responses->responses|getReviewSnapshot.evidence->evidence,getReviewSnapshot.automatedGates->gate_evidence|getReviewSnapshot.unresolvedBlockers->unresolved_blockers,getReviewSnapshot.independence->independence_risks|submitReview.$projection.decision_receipt->decision_receipt
REV-003|getPublishConfirmation.id->snapshot_id,getPublishConfirmation.version->snapshot_version|getPublishConfirmation.status->gate_state,getPublishConfirmation.updatedAt->evaluated_at|getPublishConfirmation.summary->publication_impact,getPublishConfirmation.data->affected_routes|getPublishConfirmation.links->gate_evidence,getPublicationReceipt.links->publication_receipt_links|getPublishConfirmation.data->blocking_gates|getPublicationReceipt.$projection.public_smoke_receipt->public_smoke_receipt
COR-001|listCorrectionQueue.$projection.urgent_object->urgent_object|listCorrectionQueue.$projection.requests_state->requests_state|listCorrectionQueue.$projection.requests_answer->requests_answer|listCorrectionQueue.$projection.requests_evidence->requests_evidence|listCorrectionQueue.$projection.urgent_unknown->urgent_unknown|listCorrectionQueue.$projection.requests_next_action->requests_next_action
COR-002|getCorrectionWorkspace.id->correction_id,getCorrectionWorkspace.version->correction_version|getCorrectionWorkspace.status->workspace_status,getCorrectionWorkspace.updatedAt->updated_at|getCorrectionWorkspace.summary->investigation_summary,getCorrectionWorkspace.data->proposed_correction|getCorrectionWorkspace.links->original_and_review_evidence|getCorrectionWorkspace.data->impact_and_unknowns|getCorrectionWorkspace.links->decision_actions
SRC-001|listInternalSources.$projection.ownership_object->ownership_object|listInternalSources.$projection.health_state->health_state|listInternalSources.$projection.registry_answer->registry_answer|listInternalSources.$projection.impact_evidence->impact_evidence|listInternalSources.$projection.health_unknown->health_unknown|listInternalSources.$projection.registry_next_action->registry_next_action
SRC-002|getInternalSource.id->source_id,getInternalSource.version->source_version|getInternalSource.status->source_status,getInternalSource.updatedAt->updated_at|getInternalSource.summary->quality_summary,getInternalSource.data->checkpoint_and_schema|getInternalSource.links->runbook_and_schema_evidence|getInternalSource.data->downstream_unknowns|getInternalSource.links->source_actions
SRC-003|listSourceRuns.$projection.summary_object->summary_object|listSourceRuns.$projection.runs_state->runs_state|listSourceRuns.$projection.runs_answer->runs_answer|listSourceRuns.$projection.schedule_evidence->schedule_evidence|listSourceRuns.$projection.runs_unknown->runs_unknown|listSourceRuns.$projection.runs_next_action->runs_next_action
SRC-004|getSourceRun.id->run_id,getSourceRun.version->run_version|getSourceRun.status->run_status,getSourceRun.updatedAt->updated_at|getSourceRun.summary->record_flow_summary,getSourceRun.data->errors|getSourceRun.links->artifacts_and_audit|getSourceRun.data->impact_and_unknowns|getSourceRun.links->recovery_actions
SRC-005|getSchemaDrift.id->drift_id,getSchemaDrift.version->drift_version|getSchemaDrift.status->decision_state,getSchemaDrift.updatedAt->detected_at|getSchemaDrift.summary->schema_diff_summary,getSchemaDrift.data->mapping_impact|getSchemaDrift.links->samples_and_shadow_evidence|getSchemaDrift.data->impact_unknowns|getSchemaDrift.links->mapping_decision_actions
SRC-006|estimateBackfill.id->backfill_plan_id,estimateBackfill.version->plan_version|estimateBackfill.status->progress_state,estimateBackfill.updatedAt->estimated_at|estimateBackfill.summary->estimate_summary,estimateBackfill.data->downstream_impact|estimateBackfill.links->dedupe_and_checkpoint_evidence|estimateBackfill.data->safety_unknowns|estimateBackfill.links->approval_and_start_actions
RULE-001|listInternalRules.$projection.status_object->status_object|listInternalRules.$projection.status_state->status_state|listInternalRules.$projection.registry_answer->registry_answer|listInternalRules.$projection.changes_evidence->changes_evidence|listInternalRules.$projection.changes_unknown->changes_unknown|listInternalRules.$projection.registry_next_action->registry_next_action
RULE-002|getInternalRuleVersion.id->rule_id,getInternalRuleVersion.version->rule_version|getInternalRuleVersion.status->approval_state,getInternalRuleVersion.updatedAt->updated_at|getInternalRuleVersion.summary->definition_summary,getInternalRuleVersion.data->cohort_and_formula|getInternalRuleVersion.links->usage_and_change_evidence|getInternalRuleVersion.data->blockers|getInternalRuleVersion.links->draft_and_approval_actions
RULE-003|getRuleEvaluation.id->evaluation_id,getRuleEvaluation.version->evaluation_version|getRuleEvaluation.status->signoff_state,getRuleEvaluation.updatedAt->evaluated_at|getRuleEvaluation.summary->metric_summary,getRuleEvaluation.data->threshold_results|getRuleEvaluation.links->dataset_and_error_evidence|getRuleEvaluation.data->limitations|getRuleEvaluation.links->signoff_actions
RULE-004|getRuleActivationReadiness.id->rule_id,getRuleActivationReadiness.version->rule_version|getRuleActivationReadiness.status->gate_state,getRuleActivationReadiness.updatedAt->evaluated_at|getRuleActivationReadiness.summary->impact_summary,getRuleActivationReadiness.data->activation_plan|getRuleActivationReadiness.links->rollback_and_evaluation_evidence|getRuleActivationReadiness.data->blocking_gates|getRuleActivationReadiness.links->approval_actions
OPS-001|getOperationsOverview.systemStatus->system_status|getOperationsOverview.incidents->incident_state,getOperationsOverview.telemetryGaps->telemetry_gap_state|getOperationsOverview.services->service_slo,getOperationsOverview.queues->queue_slo|getOperationsOverview.sources->source_evidence,getOperationsOverview.recentActions->recent_action_receipts|getOperationsOverview.incidents->incident_unknowns,getOperationsOverview.telemetryGaps->telemetry_unknowns|getOperationsOverview.incidents->incident_actions
OPS-002|listJobs.$projection.summary_object->summary_object|listJobs.$projection.jobs_state->jobs_state|listJobs.$projection.jobs_answer->jobs_answer|listJobs.$projection.runbook_evidence->runbook_evidence|listJobs.$projection.jobs_unknown->jobs_unknown|listJobs.$projection.jobs_next_action->jobs_next_action
OPS-003|getJob.id->job_id,getJob.version->job_version|getJob.status->job_state,getJob.updatedAt->updated_at|getJob.summary->effect_summary,getJob.data->attempts_and_effects|getJob.links->audit_and_receipts|getJob.data->possible_effect_unknowns|getJob.links->recovery_actions
OPS-004|getBudgetOverview.id->budget_id,getBudgetOverview.version->budget_version|getBudgetOverview.status->budget_state,getBudgetOverview.updatedAt->as_of|getBudgetOverview.summary->forecast_summary,getBudgetOverview.data->spend_and_value|getBudgetOverview.links->cost_evidence|getBudgetOverview.data->alerts_and_unknowns|getBudgetOverview.links->limit_actions
OPS-005|listProviders.$projection.status_object->status_object|listProviders.$projection.status_state->status_state|listProviders.$projection.latency_answer->latency_answer|listProviders.$projection.privacy_evidence->privacy_evidence|listProviders.$projection.incidents_unknown->incidents_unknown|listProviders.$projection.status_next_action->status_next_action
OPS-006|listKillSwitches.$projection.active_object->active_object|listKillSwitches.$projection.active_state->active_state|listKillSwitches.$projection.impact_answer->impact_answer|listKillSwitches.$projection.history_evidence->history_evidence|listKillSwitches.$projection.approval_unknown->approval_unknown|listKillSwitches.$projection.approval_next_action->approval_next_action
AUD-001|searchAuditEvents.$projection.query_object->query_object|searchAuditEvents.$projection.integrity_state->integrity_state|searchAuditEvents.$projection.events_answer->events_answer|searchAuditEvents.$projection.integrity_evidence->integrity_evidence|searchAuditEvents.$projection.events_unknown->events_unknown|searchAuditEvents.$projection.events_next_action->events_next_action
ADM-001|listUsers.$projection.summary_object->summary_object|listUsers.$projection.review_state->review_state|listUsers.$projection.users_answer->users_answer|listUsers.$projection.review_evidence->review_evidence|listUsers.$projection.requests_unknown->requests_unknown|listUsers.$projection.review_next_action->review_next_action
ADM-002|getUserAccessDetail.id->user_id,getUserAccessDetail.version->access_version|getUserAccessDetail.status->access_state,getUserAccessDetail.updatedAt->updated_at|getUserAccessDetail.summary->role_summary,getUserAccessDetail.data->roles_and_sessions|getUserAccessDetail.links->activity_evidence|getUserAccessDetail.data->conflicts|getUserAccessDetail.links->access_change_actions
ADM-003|listRoleDefinitions.$projection.catalog_object->catalog_object|listRoleDefinitions.$projection.review_state->review_state|listRoleDefinitions.$projection.capabilities_answer->capabilities_answer|listRoleDefinitions.$projection.history_evidence->history_evidence|listRoleDefinitions.$projection.conflicts_unknown->conflicts_unknown|listRoleDefinitions.$projection.review_next_action->review_next_action
ACC-001|getCurrentAccount.id->account_id,getCurrentAccount.version->account_version|getCurrentAccount.status->account_state,getCurrentAccount.updatedAt->updated_at|getCurrentAccount.summary->session_summary,getCurrentAccount.data->roles_and_sessions|getCurrentAccount.links->security_evidence|getCurrentAccount.data->access_request_unknowns|getCurrentAccount.links->session_actions
""",
    7,
)


# Sections not selected as one of the six ten-second semantic anchors still own
# product information and controls.  These rows are authored, not inferred:
# generation fails if their key set is anything other than the catalog section
# set minus the six-anchor union.  ``$projection`` identifies an exact closed
# screen projection that the owning API/BFF must implement; it is a runtime
# implementation dependency, never a design placeholder.
SECTION_SUPPLEMENTAL_BINDING_ROWS = parse_rows(
    r"""
PUB-001.method|listPublicCases.$projection.methodology_projection->methodology_projection
PUB-003.pagination|listPublicCases.nextCursor->pagination_next_cursor,listPublicCases.totalApproximate->pagination_total_approximate,listPublicCases.asOf->pagination_as_of
PUB-004.response|getPublicCase.partyResponses->response_party_responses
PUB-004.comparison|getPublicCase.comparison->comparison_model
PUB-004.counter|getPublicCase.counterEvidence->counter_evidence
PUB-004.timeline|getPublicCase.timeline->timeline_items
PUB-004.revision|getPublicCase.revision->revision_number,getPublicCase.corrections->revision_corrections
PUB-006.cohort|getCaseReproducibility.includedCohort->included_cohort,getCaseReproducibility.excludedCohort->excluded_cohort
PUB-008.cases|listAgencyCases.items->case_rows,listAgencyCases.nextCursor->case_next_cursor,listAgencyCases.asOf->case_as_of
PUB-010.cases|listSupplierCases.items->case_rows,listSupplierCases.nextCursor->case_next_cursor,listSupplierCases.asOf->case_as_of
PUB-012.related|getContract.relatedCases->related_cases
PUB-014.inputs|getRule.$projection.required_input_projection->required_input_projection
PUB-014.blockers|getRule.$projection.blocking_condition_projection->blocking_condition_projection
PUB-015.changes|getCoverage.$projection.coverage_change_projection->coverage_change_projection
PUB-017.quality|getSource.$projection.quality_projection->quality_projection
PUB-019.impact|getCorrection.$projection.impact_projection->impact_projection
PUB-020.schemas|listPublicDatasets.$projection.schema_dictionary_projection->schema_dictionary_projection
PUB-020.corrections|listPublicDatasets.$projection.correction_semantics_projection->correction_semantics_projection
PUB-021.pagination|getPublicApiDocumentation.$projection.pagination_contract_projection->pagination_contract_projection
PUB-022.team|getAboutContent.$projection.operating_entity_projection->operating_entity_projection
PUB-023.expenses|getFundingContent.$projection.expense_projection->expense_projection
PUB-023.donors|getFundingContent.$projection.donor_disclosure_projection->donor_disclosure_projection
PUB-025.language|getEditorialPolicy.$projection.language_policy_projection->language_policy_projection
PUB-025.response|getEditorialPolicy.$projection.right_of_reply_projection->right_of_reply_projection
PUB-027.issue|getCorrectionRequestDraft.requestedChanges->requested_changes,getCorrectionRequestDraft.version->draft_version
PUB-029.frequency|createSubscription.$projection.frequency_choice_projection->frequency_choice_projection
PUB-030.topics|getSubscription.$projection.topic_projection->topic_projection
PUB-030.unsubscribe|getSubscription.id->subscription_id,getSubscription.status->subscription_status
PUB-031.categories|getPrivacyPolicy.$projection.data_category_projection->data_category_projection
PUB-031.purposes|getPrivacyPolicy.$projection.processing_purpose_projection->processing_purpose_projection
PUB-031.processors|getPrivacyPolicy.$projection.processor_projection->processor_projection
PUB-032.prohibited|getTerms.$projection.prohibited_use_projection->prohibited_use_projection
RSP-002.support|getResponseRequest.contact->support_contact,getResponseRequest.dueAt->support_deadline
RSP-004.upload|createResponseAttachmentUpload.$projection.upload_target_projection->upload_target_projection
RSP-005.authority|getResponseSubmissionPreview.$projection.authority_attestation_projection->authority_attestation_projection
RSP-006.download|getResponseReceipt.$projection.receipt_download_projection->receipt_download_projection
INT-001.queues|getInternalDashboard.$projection.queue_projection->queue_projection
INT-002.filters|listMyTasks.appliedFilters->task_filters
INT-003.types|searchInternalRecords.appliedFilters->type_filters
SIG-001.filters|listSignals.appliedFilters->signal_filters
SIG-001.bulk|listSignals.$projection.bulk_selection_projection->bulk_selection_projection
SIG-002.related|getSignalTriageView.$projection.related_case_projection->related_case_projection
SIG-002.ai|getSignalTriageView.$projection.ai_assistance_projection->ai_assistance_projection
CAS-004.filters|listCaseEvidence.appliedFilters->evidence_filters
CAS-005.relationships|getEvidenceWorkspace.$projection.relationship_projection->relationship_projection
CAS-009.deadline|getResponseRequestComposer.$projection.deadline_projection->deadline_projection
CAS-010.filters|listCaseAgentRuns.appliedFilters->agent_run_filters
CAS-011.inputs|getAgentRun.$projection.agent_input_projection->agent_input_projection
CAS-011.model|getAgentRun.$projection.provider_turn_projection->provider_turn_projection
CAS-011.cost|getAgentRun.$projection.cost_projection->cost_projection
CAS-013.snapshot|createReviewSnapshot.$projection.snapshot_receipt_projection->snapshot_receipt_projection
CAS-014.variants|getPublicationPreview.$projection.route_variant_projection->route_variant_projection
CAS-015.requests|listCaseCorrections.$projection.request_projection->request_projection
CAS-016.filters|listCaseAuditEvents.appliedFilters->audit_filters
REV-001.filters|listReviewQueue.appliedFilters->review_filters
REV-002.diff|getReviewSnapshot.$projection.readable_diff_projection->readable_diff_projection
REV-003.receipt|getPublicationReceipt.$projection.publication_receipt_projection->publication_receipt_projection
COR-001.filters|listCorrectionQueue.appliedFilters->correction_filters
COR-001.assignment|listCorrectionQueue.$projection.assignment_projection->assignment_projection
COR-002.proposal|getCorrectionWorkspace.$projection.proposal_projection->proposal_projection
COR-002.receipt|getCorrectionWorkspace.$projection.receipt_projection->receipt_projection
SRC-001.filters|listInternalSources.appliedFilters->source_filters
SRC-002.checkpoint|getInternalSource.$projection.checkpoint_projection->checkpoint_projection
SRC-003.filters|listSourceRuns.appliedFilters->source_run_filters
SRC-004.scope|getSourceRun.$projection.run_scope_projection->run_scope_projection
SRC-005.mapping|getSchemaDrift.$projection.mapping_projection->mapping_projection
SRC-005.shadow|getSchemaDrift.$projection.shadow_result_projection->shadow_result_projection
SRC-006.downstream|estimateBackfill.$projection.downstream_impact_projection->downstream_impact_projection
RULE-001.filters|listInternalRules.appliedFilters->rule_filters
RULE-002.cohort|getInternalRuleVersion.$projection.cohort_projection->cohort_projection
RULE-002.diff|getInternalRuleVersion.$projection.diff_projection->diff_projection
RULE-003.threshold|getRuleEvaluation.$projection.threshold_projection->threshold_projection
RULE-003.shadow|getRuleEvaluation.$projection.shadow_projection->shadow_projection
RULE-004.schedule|getRuleActivationReadiness.$projection.schedule_projection->schedule_projection
RULE-004.receipt|getRuleActivationReadiness.$projection.activation_receipt_projection->activation_receipt_projection
OPS-001.pipelines|getOperationsOverview.$projection.pipeline_projection->pipeline_projection
OPS-001.queues|getOperationsOverview.queues->queue_rows
OPS-001.cost|getOperationsOverview.$projection.cost_projection->cost_projection
OPS-002.filters|listJobs.appliedFilters->job_filters
OPS-002.bulk|listJobs.$projection.bulk_selection_projection->bulk_selection_projection
OPS-003.attempts|getJob.$projection.attempt_projection->attempt_projection
OPS-003.payload|getJob.$projection.redacted_payload_projection->redacted_payload_projection
OPS-005.quotas|listProviders.$projection.quota_projection->quota_projection
OPS-005.fallback|listProviders.$projection.fallback_projection->fallback_projection
OPS-005.model-catalog|listRelayModels.items->model_rows,listRelayModels.currentProviders->current_providers,listRelayModels.syncStatus->sync_status,listRelayModels.asOf->as_of
OPS-006.catalog|listKillSwitches.items->kill_switch_rows
OPS-006.runbook|listKillSwitches.$projection.runbook_projection->runbook_projection
AUD-001.filters|searchAuditEvents.appliedFilters->audit_filters
AUD-001.export|getAuditExport.$projection.export_projection->export_projection
ADM-001.filters|listUsers.appliedFilters->user_filters
ADM-002.sessions|getUserAccessDetail.$projection.session_projection->session_projection
ADM-002.offboarding|getUserAccessDetail.$projection.offboarding_projection->offboarding_projection
ADM-003.grants|listRoleDefinitions.$projection.grant_projection->grant_projection
ACC-001.roles|getCurrentAccount.$projection.role_projection->role_projection
ACC-001.notifications|getCurrentAccount.$projection.notification_projection->notification_projection
""",
    2,
)


PROFILE_STATE_LABELS = {
    "awaiting-query": "검색어 입력 대기",
    "initial-loading": "처음 불러오는 중",
    "loading": "불러오는 중",
    "refreshing": "새 정보를 확인하는 중",
    "empty": "확인된 항목 없음",
    "filtered-empty": "선택한 조건의 항목 없음",
    "partial": "일부 정보만 확인됨",
    "stale": "최신성 확인 필요",
    "invalid-filter": "검색 조건 수정 필요",
    "error": "정보를 불러오지 못함",
    "offline": "네트워크 연결 없음",
    "success": "최신 정보 확인됨",
    "current": "현재 적용 중",
    "superseded": "새 버전으로 대체됨",
    "draft": "작성 중",
    "saving": "저장하는 중",
    "saved": "서버에 저장됨",
    "validation-error": "입력 수정 필요",
    "server-error": "서버 처리 실패",
    "session-expiring": "세션 만료 임박",
    "ready": "결정 준비 완료",
    "blocked": "선행 조건에 막힘",
    "reauth-required": "재인증 필요",
    "conflict": "다른 변경과 충돌",
    "submitting": "결정을 제출하는 중",
    "receipt": "처리 영수증 확인됨",
    "partial-failure": "주요 처리는 끝났으나 후속 작업 실패",
    "healthy": "정상 운영 중",
    "degraded": "일부 기능 저하",
    "incident": "운영 사고 대응 중",
    "telemetry-gap": "관측 정보 부족",
    "forbidden": "권한 없음",
    "unauthorized": "로그인 또는 인증 필요",
    "not-found": "요청한 화면을 찾을 수 없음",
    "unauthenticated": "로그인 필요",
    "session-expired": "세션 만료",
    "maintenance": "계획된 점검 중",
}


MANIFEST_STATE_SIGNAL_PATHS = {
    "awaiting-query": "runtimeSignals.queryPresent",
    "loading": "runtimeSignals.blockingPending",
    "success": "runtimeSignals.outcomeState",
    "empty": "runtimeSignals.authorizedRecordCount",
    "partial": "runtimeSignals.requiredSliceComplete",
    "stale": "runtimeSignals.freshnessState",
    "error": "runtimeSignals.blockingFailure",
    "unauthorized": "runtimeSignals.accessDecision",
    "forbidden": "runtimeSignals.accessDecision",
    "conflict": "runtimeSignals.concurrencyResult",
}


MANIFEST_STATE_REFINEMENTS = {
    "public-data": {
        "loading": ["initial-loading", "refreshing"],
        "success": ["success"],
        "empty": ["empty", "filtered-empty"],
        "partial": ["partial"],
        "stale": ["stale"],
        "error": ["error", "offline"],
    },
    "public-search": {
        "awaiting-query": ["awaiting-query"],
        "loading": ["initial-loading", "refreshing"],
        "success": ["success"],
        "empty": ["empty", "filtered-empty"],
        "partial": ["partial"],
        "stale": ["stale"],
        "error": ["error", "offline"],
    },
    "guided-submission": {
        "loading": ["loading"],
        "success": ["success", "saved"],
        "empty": [],
        "partial": ["draft", "validation-error"],
        "stale": ["session-expiring"],
        "error": ["server-error", "offline"],
        "unauthorized": [],
        "forbidden": [],
        "conflict": [],
    },
    "internal-data": {
        "loading": ["loading", "refreshing"],
        "success": [],
        "empty": ["empty"],
        "partial": ["partial"],
        "stale": [],
        "error": ["error"],
        "unauthorized": ["unauthorized"],
        "forbidden": ["forbidden"],
        "conflict": ["conflict"],
    },
    "system": {
        "loading": [],
        "success": [],
        "empty": ["not-found"],
        "partial": ["degraded"],
        "stale": ["degraded"],
        "error": ["error", "offline", "maintenance"],
        "unauthorized": ["unauthenticated", "session-expired"],
        "forbidden": ["forbidden"],
        "conflict": [],
    },
}


# state | Korean label | explicit semantic category
SPECIAL_STATE_ROWS = parse_rows(
    r"""
access-restricted|접근 제한|access
account-disabled|계정 비활성화|access
activation-pending|활성화 대기|pending
active|활성|success
active-correction|정정 적용 중|success
active-critical|중요 기능 중지 활성|blocked
active-incident|운영 사고 진행 중|degraded
active-run|실행 진행 중|pending
all-blocked|모든 경로 차단|blocked
all-healthy|모든 항목 정상|success
already-pending|이미 처리 대기 중|pending
already-submitted|이미 제출됨|receipt
already-subscribed|이미 구독 중|success
already-unsubscribed|이미 구독 해지됨|terminal
amended|수정본 적용됨|success
api-deprecation|API 지원 종료 예정|stale
approval-conflict|승인 결정 충돌|conflict
autosave-failed|자동 저장 실패|failure
backlog-sla-breach|대기 업무 처리기한 초과|blocked
blocked|선행 조건에 막힘|blocked
blocker-present|해결할 차단 요인 있음|blocked
blocking-gates|필수 검증 미통과|blocked
break-glass-active|비상 접근 활성|security
breaking-change|호환되지 않는 변경|blocked
broken-evidence-link|근거 연결 손상|failure
broken-source-link|원문 연결 손상|failure
budget-exceeded|예산 초과|blocked
budget-exhausted|예산 소진|blocked
budget-limited|예산 제한 적용|degraded
calculation-failed|계산 실패|failure
callback-error|회신 처리 오류|failure
cancelled|취소됨|terminal
checkpoint-corrupt|체크포인트 손상|failure
checkpoint-gap|체크포인트 누락|failure
citation-missing|인용 근거 누락|blocked
clock-skew-warning|시각 오차 주의|stale
conflict-detected|변경 충돌 감지|conflict
contact-unverified|연락처 미검증|blocked
corrected|정정됨|success
coverage-change|데이터 범위 변경|stale
coverage-empty|수집 범위 없음|empty
credentials-expiring|연결 자격 만료 임박|blocked
dataset-building|데이터 묶음 생성 중|pending
deadline-passed|기한 지남|blocked
definition-invalid|정의가 유효하지 않음|validation
degraded|일부 기능 저하|degraded
degraded-read-only|읽기 전용으로 제한|degraded
delivery-degraded|전달 기능 저하|degraded
delivery-delayed|전달 지연|pending
delivery-failed|전달 실패|failure
deprecated-role|지원 종료 예정 역할|stale
dlq-spike|실패 대기열 급증|degraded
draft-conflict|초안 변경 충돌|conflict
draft-not-saved|초안 미저장|failure
draft-preserved|초안 보존됨|success
duplicate-candidate|중복 후보 발견|conflict
duplicate-command|중복 실행 요청|conflict
duplicate-request|중복 요청|conflict
duplicate-submit|중복 제출 방지|conflict
email-suppressed|이메일 발송 억제|degraded
empty|표시할 항목 없음|empty
entity-merged|대상 병합됨|terminal
entity-split|대상 분리됨|stale
estimate-stale|예상치 최신성 만료|stale
evaluation-stale|평가 결과 최신성 만료|stale
event-gap|감사 이벤트 누락|failure
evidence-insufficient|근거 부족|blocked
evidence-missing|근거 누락|blocked
expired|유효기간 만료|terminal
expired-not-restored|만료 후 복구되지 않음|blocked
export-pending|내보내기 준비 중|pending
extension-approved|기한 연장 승인|success
extension-denied|기한 연장 거절|terminal
extension-pending|기한 연장 검토 중|pending
failure-streak|연속 실패|degraded
fallback-active|대체 경로 사용 중|degraded
filtered-empty|선택 조건의 결과 없음|empty
forecast-uncertain|예측 불확실|stale
form-rate-limited|양식 요청 속도 제한|degraded
gate-changed|검증 조건 변경|conflict
gate-failed|검증 조건 미통과|blocked
hard-limit|강제 한도 도달|blocked
hash-mismatch|무결성 값 불일치|failure
identity-ambiguous|대상 식별 불명확|blocked
identity-update|대상 식별 정보 변경|stale
idp-disabled|로그인 공급자 비활성|access
idp-sync-delay|계정 동기화 지연|pending
idp-sync-error|계정 동기화 실패|failure
idp-unavailable|로그인 공급자 이용 불가|degraded
impact-analysis-incomplete|영향 분석 미완료|blocked
incident|운영 사고 발생|degraded
independence-conflict|독립성 충돌|blocked
indexing-lag|검색 반영 지연|stale
insufficient-evaluation|평가 자료 부족|blocked
insufficient-sample|표본 부족|blocked
integrity-gap|무결성 자료 누락|failure
integrity-warning|무결성 주의|blocked
invalid|유효하지 않음|validation
invalid-filter|검색 조건 오류|validation
invalid-money-sort|금액 정렬 기준 오류|validation
invalid-target|대상 오류|validation
invalid-topic|구독 대상 오류|validation
large-export|큰 내보내기 준비 필요|pending
large-result|결과가 매우 많음|degraded
lease-stuck|작업 점유 해제 실패|failure
legal-hold|법률 보존 적용|blocked
legal-review-required|법률 검토 필요|blocked
license-restricted|이용권한 제한|access
link-conflict|연결 정보 충돌|conflict
maintenance|점검 중|degraded
major-incident|중대 운영 사고|degraded
method-unavailable|방법론 정보 이용 불가|failure
missing-required-answer|필수 답변 누락|validation
more-information-requested|추가 정보 요청됨|pending
multiple-stale|여러 정보의 최신성 만료|stale
network-retry|네트워크 재연결 대기|pending
no-active-rules|활성 규칙 없음|empty
no-assigned-work|배정된 업무 없음|empty
no-corrections|정정 기록 없음|empty
no-hypotheses|등록된 가설 없음|empty
no-publications|공개 기록 없음|empty
no-published-cases|공개 사건 없음|empty
no-related-case|연결 사건 없음|empty
no-request|접수된 요청 없음|empty
no-results|검색 결과 없음|empty
no-runs|실행 기록 없음|empty
no-sample|검증 표본 없음|empty
no-signals|신호 없음|empty
not-found|대상을 찾을 수 없음|empty
not-latest|최신본 아님|stale
offboarding|사용 종료 절차 진행 중|pending
offboarding-due|사용 종료 처리 기한 임박|blocked
offline|네트워크 연결 없음|degraded
overdue|처리기한 초과|blocked
partial-coverage|일부 범위만 수집됨|degraded
partial-failure|일부 처리 실패|failure
partial-fields|일부 필드 누락|degraded
partial-stale|일부 정보 최신성 만료|stale
partial-success|일부 처리 완료|degraded
paused|일시 중지|degraded
payload-redacted|민감 내용 가림|security
pending-approval|승인 대기|pending
permission-changed|권한 변경됨|access
permission-filtered|권한에 따라 결과 제한|access
permission-read-only|읽기 권한만 있음|access
policy-denied|정책에 의해 거부|access
policy-version-updated|정책 버전 변경|stale
preview-stale|미리보기 최신성 만료|stale
privacy-policy-expired|개인정보 정책 확인 필요|blocked
privacy-redacted|개인정보 가림|security
private-data-detected|개인정보 감지|security
prohibited-language|허용되지 않는 표현 감지|validation
projection-failed|공개 화면 반영 실패|failure
projection-pending|공개 화면 반영 중|pending
prompt-injection-flag|외부 지시문 위험 감지|security
provider-billing-lag|공급자 비용 반영 지연|stale
provider-outage|외부 공급자 장애|degraded
provider-timeout|외부 공급자 응답 지연|failure
provider-unavailable|외부 공급자 이용 불가|degraded
public-impact-active|공개 서비스 영향 발생|degraded
publication-blocked|게시 차단|blocked
quarantine-spike|격리 자료 급증|degraded
query-too-short|검색어가 너무 짧음|validation
queue-paused|작업 대기열 중지|degraded
quota-exceeded|사용량 한도 초과|blocked
quota-low|남은 사용량 부족|blocked
rate-limit-incident|요청 제한 사고|degraded
rate-limited|요청 속도 제한|degraded
reauth-required|재인증 필요|access
receipt-expired-link|영수증 링크 만료|access
receipt-temporarily-unavailable|영수증 일시 이용 불가|failure
redacted-event|민감 감사 내용 가림|security
redacted-input|민감 입력 가림|security
regression|품질 회귀 감지|blocked
renamed-or-merged|이름 변경 또는 병합|stale
render-error|화면 구성 실패|failure
request-updated|요청 내용 변경|stale
response-not-linked|소명 연결 누락|failure
response-overdue|소명 기한 초과|blocked
response-window-open|소명 가능 기간|success
restricted-event|제한된 감사 이벤트|access
restricted-evidence|제한된 근거|access
restricted-input|제한된 입력|access
retired|사용 종료|terminal
retired-rule|규칙 사용 종료|terminal
retired-source|출처 사용 종료|terminal
retracted|철회됨|terminal
retraction|철회 절차 진행|pending
retry-unsafe|안전한 재시도 불가|blocked
review-backlog|검토 대기 증가|degraded
review-overdue|검토 기한 초과|blocked
revoked|회수됨|terminal
role-expiring|역할 만료 임박|blocked
role-missing|필요 역할 없음|access
rollback-required|되돌리기 필요|blocked
rule-incident|규칙 운영 사고|degraded
rule-retired|규칙 사용 종료|terminal
scan-pending|파일 검사 중|pending
scan-rejected|파일 검사 거절|blocked
schema-drift|자료 구조 변경 감지|blocked
schema-invalid|자료 구조 오류|validation
schema-mismatch|자료 구조 불일치|validation
scope-mismatch|요청 범위 불일치|validation
server-error|서버 처리 실패|failure
session-expiring|세션 만료 임박|blocked
session-risk|세션 위험 감지|security
shadow-active|검증 실행 중|pending
shadow-failed|검증 실행 실패|failure
side-effect-uncertain|외부 실행 결과 불확실|blocked
signal-in-other-case|다른 사건에 연결된 신호|conflict
sla-breach|서비스 목표 위반|degraded
snapshot-stale|검토본 최신성 만료|conflict
snapshot-superseded|검토본 대체됨|terminal
sod-conflict|직무분리 충돌|blocked
soft-limit|권고 한도 도달|degraded
source-field-missing|출처 필드 누락|failure
source-incident|출처 수집 사고|degraded
source-license-limited|출처 이용권한 제한|access
source-link-lost|출처 연결 끊김|failure
source-lost|출처 이용 불가|failure
source-stale|출처 최신성 만료|stale
stale|최신성 만료|stale
stale-grants|오래된 권한 부여|access
stale-review|검토 결과 최신성 만료|conflict
submission-quarantined|제출 자료 격리|security
submission-receipt|제출 영수증 발급|receipt
submit-conflict|제출 충돌|conflict
superseded|새 버전으로 대체|terminal
superseded-by-correction|정정본으로 대체|terminal
supplement-requested|추가자료 요청됨|pending
synthetic-demo|합성 예시 데이터|security
telemetry-gap|관측 정보 누락|failure
temporary-legal-restriction|임시 법률 제한|blocked
terms-review-required|이용 조건 검토 필요|blocked
token-expired|접근 링크 만료|access
token-expiring|접근 링크 만료 임박|blocked
token-revoked|접근 링크 회수|access
type-not-allowed|허용되지 않는 파일 유형|validation
unsupported-conclusion|근거로 뒷받침되지 않는 결론|validation
upload-scanning|업로드 파일 검사 중|pending
uploading|파일 업로드 중|pending
urgent-backlog|긴급 업무 대기 증가|degraded
urgent-privacy|긴급 개인정보 검토|blocked
urgent-privacy-path|긴급 개인정보 처리 경로|blocked
used|이미 사용됨|terminal
verification-failed|검증 실패|failure
verification-pending|검증 대기|pending
verification-required|검증 필요|blocked
verification-sent|검증 안내 발송|pending
version-conflict|버전 충돌|conflict
""",
    3,
)


CATEGORY_CONTRACTS = {
    "access": {
        "rank": 930,
        "preserve": "보호된 대상의 존재를 노출하지 않고 입력과 안전한 돌아가기 경로를 보존한다.",
        "action": "인증·권한을 복구하거나 안전한 화면으로 돌아간다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
    "blocked": {
        "rank": 900,
        "preserve": "대상 무결성 값, 마지막 서버 저장본, 차단 근거와 입력을 보존한다.",
        "action": "표시된 차단 요인을 해결한 뒤 같은 대상을 다시 검증한다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
    "conflict": {
        "rank": 920,
        "preserve": "사용자 입력, 서버 버전, 시도한 변경과 읽을 수 있는 차이를 보존한다.",
        "action": "최신본과 변경 차이를 확인하고 명시적으로 다시 적용한다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
    "degraded": {
        "rank": 760,
        "preserve": "영향 범위, 마지막 정상 시각, 확인된 데이터와 안전한 대체 경로를 보존한다.",
        "action": "영향받지 않은 읽기 행동만 허용하고 복구 상태를 확인한다.",
        "live": "polite-once",
        "retry": "STATE_SPECIFIC",
    },
    "empty": {
        "rank": 300,
        "preserve": "조회 범위, 검색 조건과 결과가 0건이라는 서버 확인을 보존한다.",
        "action": "범위나 조건을 명시적으로 바꾸거나 안전한 상위 화면으로 돌아간다.",
        "live": "polite-once",
        "retry": "STATE_SPECIFIC",
    },
    "failure": {
        "rank": 950,
        "preserve": "마지막 확인 데이터, 저장 여부, 실패 범위와 지원 참조번호를 보존한다.",
        "action": "중복 외부 효과 가능성을 확인한 뒤 안전한 경우에만 재시도한다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
    "pending": {
        "rank": 520,
        "preserve": "현재 입력, 서버가 확인한 진행 단계와 중복 방지 키를 보존한다.",
        "action": "진행 결과를 기다리며 별도 실행을 중복 제출하지 않는다.",
        "live": "polite-once",
        "retry": "NO_BLIND_RETRY",
    },
    "receipt": {
        "rank": 610,
        "preserve": "영수증 번호, 대상 무결성 값, 처리 시각과 후속 링크를 보존한다.",
        "action": "영수증을 보관하고 표시된 다음 절차로 이동한다.",
        "live": "polite-once-after-completion",
        "retry": "NO_BLIND_RETRY",
    },
    "security": {
        "rank": 970,
        "preserve": "민감 원문은 노출하지 않고 안전한 요약, 근거 ID와 감사 참조만 보존한다.",
        "action": "보안·개인정보 검토 경로로 이동하고 위험한 행동을 중지한다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
    "stale": {
        "rank": 700,
        "preserve": "마지막 검증 시각, 적용 버전과 최신성이 만료된 범위를 보존한다.",
        "action": "현재 자료를 읽기 전용으로 유지하고 최신본을 다시 확인한다.",
        "live": "polite-once",
        "retry": "STATE_SPECIFIC",
    },
    "success": {
        "rank": 200,
        "preserve": "서버가 확인한 현재 상태, 적용 시각과 대상 revision을 보존한다.",
        "action": "현재 화면의 명시된 다음 행동을 이용한다.",
        "live": "polite-once-if-async",
        "retry": "STATE_SPECIFIC",
    },
    "terminal": {
        "rank": 640,
        "preserve": "종료 이유, 최종 시각, 대체 대상 또는 영수증을 보존한다.",
        "action": "종료 상태를 바꾸지 않고 이력이나 현재 유효한 대상으로 이동한다.",
        "live": "polite-once",
        "retry": "NO_BLIND_RETRY",
    },
    "validation": {
        "rank": 820,
        "preserve": "모든 유효 입력과 서버 저장본을 보존하고 오류 필드만 표시한다.",
        "action": "오류 요약에서 정확한 입력으로 이동해 수정한다.",
        "live": "assertive-once",
        "retry": "NO_BLIND_RETRY",
    },
}


SPECIAL_FOCUS_BLOCKING_CATEGORIES = {
    "access",
    "blocked",
    "conflict",
    "failure",
    "security",
    "validation",
}


# operation | Korean label | consequence
COMMAND_PRESENTATION = parse_rows(
    r"""
createActionProposal|승인 요청 초안 만들기|현재 대상·수신자·내용·영향을 하나의 변경 불가능한 승인 대상으로 묶는다.
updateActionDraft|승인 요청 초안 저장|기존 초안을 덮어쓰지 않고 새 revision으로 저장해 검토 전 변경 이력을 남긴다.
previewActionDraft|실행 결과 미리보기|실제 실행 없이 예상 수신자·내용·비용·위험·외부 효과를 계산해 보여준다.
submitActionForReview|독립 검토 요청하기|현재 초안 digest를 고정하고 작성자와 분리된 검토 대기열로 보낸다.
claimActionReview|검토 맡기|현재 검토 assignment를 본인에게 원자적으로 배정하고 기한을 시작한다.
submitActionDecision|검토 결정 제출하기|고정된 대상 digest에 승인·변경요청·거절·기피 이유를 기록하고 충족된 경우에만 다음 단계로 보낸다.
withdrawActionProposal|승인 요청 철회하기|실행 권한이 생기기 전의 현재 제안만 철회하고 배정·결정 이력과 철회 영수증은 그대로 보존한다.
withdrawActionDecision|승인 결정 철회하기|최종 정족수 확정 전 본인의 현재 승인만 철회하고 대체 검토 배정 또는 공석 상태를 명시한다.
cancelActionExecution|외부 실행 취소 요청하기|아직 외부 효과가 시작되지 않은 실행만 취소하고 이미 시작됐으면 결과 대조로 전환한다.
retryActionExecution|외부 실행 다시 시도하기|이전 실행 결과와 idempotency 범위를 확인한 뒤 안전한 실행만 새 시도로 보낸다.
promoteResearchArtifactToEvidence|조사 자료를 근거로 승격하기|고정된 자료 bytes·권리·locator·선택 구간을 다시 검증해 권위 있는 근거 revision과 영수증을 원자적으로 만든다.
cancelAgentRun|AI 조사 실행 취소 요청하기|아직 dispatch되지 않은 실행만 취소하고 외부 효과 가능성이 있으면 취소 완료로 가장하지 않고 대조 상태로 전환한다.
decideJourneyHandoff|업무 인계 응답하기|현재 인계의 대상·담당 범위·기한·후속 결과를 확인하고 맡기 또는 사유가 있는 거절을 저장된 인계 영수증으로 남긴다.
releaseLegalHold|법률 보존 해제 요청하기|정확한 보존 대상과 해제 근거를 재인증·독립 검토 후 해제하고 감사 영수증을 남긴다.
createResponseAppeal|소명 처리에 이의 제기하기|접수 영수증에 결속된 사유·요청 결과·설명·첨부를 새 이의 기록으로 제출한다.
reconcileCommunicationDelivery|전달 결과 대조하기|공급자 증거와 내부 상태를 대조해 전달됨·실패·불확실 중 하나로 확정한다.
cancelCommunicationDelivery|전달 취소 요청하기|아직 발송되지 않은 전달만 취소하고 외부 효과 가능성이 있으면 불확실 상태와 대조 과제를 남긴다.
triageIncident|운영 사고 분류하기|영향·심각도·담당자·다음 공지 시각을 확정해 사고 대응을 시작한다.
containIncident|운영 사고 확산 막기|승인된 완화 조치와 영향 범위를 기록하고 추가 확산을 제한한다.
startIncidentRecovery|운영 복구 시작하기|원인이 통제됐다는 근거와 복구 계획을 결속해 검증 가능한 복구 단계로 이동한다.
resolveIncident|운영 사고 해결하기|서비스 목표와 사용자 영향이 회복됐다는 증거를 확인해 사고를 해결 상태로 전환한다.
closeIncidentPostmortem|사후 검토 닫기|원인·영향·개선 과제·담당자·기한이 저장된 경우에만 사후 검토를 종료한다.
transitionResponseAppeal|소명 이의 결정하기|정확한 이의 revision을 접수·추가정보요청·인용검토·상태정정·종결 중 허용된 상태로 전환한다.
decideResponseExtension|소명 기한 연장 결정하기|기존 기한·요청 기한·사유·영향을 검토해 승인 또는 거절 영수증을 남긴다.
transitionRetentionRequest|보존 요청 결정하기|법적 보존과 삭제 요청을 분리해 정확한 record class·범위·근거에 허용된 결정을 남긴다.
requestCommunicationEndpointLink|메시지 수신처 연결 요청하기|선택한 이메일·문자·메신저 수신처와 동의를 검증 challenge에 결속한다.
verifyCommunicationEndpointLink|메시지 수신처 확인하기|일회용 증명과 challenge를 검증해 해당 수신처만 활성화한다.
unlinkCommunicationEndpoint|메시지 수신처 연결 해제하기|선택한 수신처만 해제하고 다른 채널·구독·감사 이력은 유지한다.
createPrivacyRequest|개인정보 요청 제출하기|요청 유형·범위·연락 방법·신원확인 방식을 접수하고 추적 가능한 영수증을 발급한다.
exchangePrivacyRequestReceiptToken|개인정보 요청 상태 열기|일회용 영수증 링크를 소비해 URL에서 비밀값을 제거하고 범위가 제한된 상태 세션을 만든다.
declareConflict|이해상충 사실 기록하기|정확한 사람·대상·관계·중요도·기간·근거를 현재 정책에 결속해 기존 기록을 덮지 않는 새 사실로 남긴다.
withdrawConflict|이해상충 해소 사실 기록하기|기존 선언의 sequence와 digest를 확인하고 과거 기록은 유지한 채 해소 근거를 새 사실로 덧붙인다.
recordSupplierIdentityResolution|공급자 식별 결정 기록하기|후보 집합·근거 digest·영향 담당자를 고정해 자동 병합 없이 사람의 식별 결정을 append-only 영수증으로 남긴다.
recordSupplierRelationshipAssertion|공급자 관계 주장 등록하기|두 당사자와 관계·기간·근거를 검증해 검토 대기 상태로 등록하고 자동 검증은 수행하지 않는다.
decideSupplierRelationshipAssertion|공급자 관계 주장 결정하기|고정된 주장 revision·근거 digest를 재확인해 검증·거절·충돌·대체 중 하나의 독립 결정을 영수증으로 남긴다.
""",
    3,
)

COMMAND_RECEIPT_PRESENTATION_OVERRIDES = {
    "decideJourneyHandoff": {
        "receipt_render_order": ["decisionReceipt", "replacement", "finalParent"],
        "success_receipt_rule": "render the immutable terminal old-handoff decision first, the optional replacement request next, and finalParent as the authoritative post-command state; a replacement WAITING_ACK view shows receiver function and hard expiry but never receiver identity bytes",
        "success_focus_source": "finalParent heading",
    }
}


# placement key | action id | selected target | form | session authority |
# receipt | destination screen | destination section | handler
COMMAND_PLACEMENT_ROWS = parse_rows(
    r"""
createActionProposal@CAS-002.next|create-action-proposal--next|view_model.sections.next.selected_target|view_model.sections.next.forms.create_action_proposal__next|request_context.review_console_session|action_result.create_action_proposal__next.validated_receipt|CAS-002|next|handle__cas_002__create_action_proposal__next
createActionProposal@CAS-006.editor|create-action-proposal--editor|view_model.sections.editor.selected_target|view_model.sections.editor.forms.create_action_proposal__editor|request_context.review_console_session|action_result.create_action_proposal__editor.validated_receipt|CAS-006|editor|handle__cas_006__create_action_proposal__editor
createActionProposal@CAS-007.board|create-action-proposal--board|view_model.sections.board.selected_target|view_model.sections.board.forms.create_action_proposal__board|request_context.review_console_session|action_result.create_action_proposal__board.validated_receipt|CAS-007|board|handle__cas_007__create_action_proposal__board
createActionProposal@CAS-009.preview|create-action-proposal--preview|view_model.sections.preview.selected_target|view_model.sections.preview.forms.create_action_proposal__preview|request_context.review_console_session|action_result.create_action_proposal__preview.validated_receipt|CAS-009|preview|handle__cas_009__create_action_proposal__preview
createActionProposal@CAS-011.decisions|create-action-proposal--decisions|view_model.sections.decisions.selected_target|view_model.sections.decisions.forms.create_action_proposal__decisions|request_context.review_console_session|action_result.create_action_proposal__decisions.validated_receipt|CAS-011|decisions|handle__cas_011__create_action_proposal__decisions
createActionProposal@CAS-015.proposal|create-action-proposal--proposal|view_model.sections.proposal.selected_target|view_model.sections.proposal.forms.create_action_proposal__proposal|request_context.review_console_session|action_result.create_action_proposal__proposal.validated_receipt|CAS-015|proposal|handle__cas_015__create_action_proposal__proposal
createActionProposal@RULE-004.approval|create-action-proposal--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.create_action_proposal__approval|request_context.review_console_session|action_result.create_action_proposal__approval.validated_receipt|RULE-004|approval|handle__rule_004__create_action_proposal__approval
createActionProposal@REV-003.gates|create-action-proposal--gates|view_model.sections.gates.selected_target|view_model.sections.gates.forms.create_action_proposal__gates|request_context.review_console_session|action_result.create_action_proposal__gates.validated_receipt|REV-003|gates|handle__rev_003__create_action_proposal__gates
createActionProposal@OPS-005.status|create-action-proposal--status|view_model.sections.status.selected_target|view_model.sections.status.forms.create_action_proposal__status|request_context.review_console_session|action_result.create_action_proposal__status.validated_receipt|INT-002|tasks|handle__ops_005__create_action_proposal__status
createActionProposal@OPS-006.approval|create-action-proposal--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.create_action_proposal__approval|request_context.review_console_session|action_result.create_action_proposal__approval.validated_receipt|OPS-006|approval|handle__ops_006__create_action_proposal__approval
createActionProposal@ADM-002.requests|create-action-proposal--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.create_action_proposal__requests|request_context.review_console_session|action_result.create_action_proposal__requests.validated_receipt|ADM-002|requests|handle__adm_002__create_action_proposal__requests
updateActionDraft@CAS-002.next|update-action-draft--next|view_model.sections.next.selected_target|view_model.sections.next.forms.update_action_draft__next|request_context.review_console_session|action_result.update_action_draft__next.validated_receipt|CAS-002|next|handle__cas_002__update_action_draft__next
updateActionDraft@CAS-006.editor|update-action-draft--editor|view_model.sections.editor.selected_target|view_model.sections.editor.forms.update_action_draft__editor|request_context.review_console_session|action_result.update_action_draft__editor.validated_receipt|CAS-006|editor|handle__cas_006__update_action_draft__editor
updateActionDraft@CAS-007.board|update-action-draft--board|view_model.sections.board.selected_target|view_model.sections.board.forms.update_action_draft__board|request_context.review_console_session|action_result.update_action_draft__board.validated_receipt|CAS-007|board|handle__cas_007__update_action_draft__board
updateActionDraft@CAS-009.preview|update-action-draft--preview|view_model.sections.preview.selected_target|view_model.sections.preview.forms.update_action_draft__preview|request_context.review_console_session|action_result.update_action_draft__preview.validated_receipt|CAS-009|preview|handle__cas_009__update_action_draft__preview
updateActionDraft@CAS-011.decisions|update-action-draft--decisions|view_model.sections.decisions.selected_target|view_model.sections.decisions.forms.update_action_draft__decisions|request_context.review_console_session|action_result.update_action_draft__decisions.validated_receipt|CAS-011|decisions|handle__cas_011__update_action_draft__decisions
updateActionDraft@CAS-015.proposal|update-action-draft--proposal|view_model.sections.proposal.selected_target|view_model.sections.proposal.forms.update_action_draft__proposal|request_context.review_console_session|action_result.update_action_draft__proposal.validated_receipt|CAS-015|proposal|handle__cas_015__update_action_draft__proposal
updateActionDraft@RULE-004.approval|update-action-draft--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.update_action_draft__approval|request_context.review_console_session|action_result.update_action_draft__approval.validated_receipt|RULE-004|approval|handle__rule_004__update_action_draft__approval
updateActionDraft@REV-003.gates|update-action-draft--gates|view_model.sections.gates.selected_target|view_model.sections.gates.forms.update_action_draft__gates|request_context.review_console_session|action_result.update_action_draft__gates.validated_receipt|REV-003|gates|handle__rev_003__update_action_draft__gates
updateActionDraft@OPS-005.status|update-action-draft--status|view_model.sections.status.selected_target|view_model.sections.status.forms.update_action_draft__status|request_context.review_console_session|action_result.update_action_draft__status.validated_receipt|OPS-005|status|handle__ops_005__update_action_draft__status
updateActionDraft@OPS-006.approval|update-action-draft--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.update_action_draft__approval|request_context.review_console_session|action_result.update_action_draft__approval.validated_receipt|OPS-006|approval|handle__ops_006__update_action_draft__approval
updateActionDraft@ADM-002.requests|update-action-draft--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.update_action_draft__requests|request_context.review_console_session|action_result.update_action_draft__requests.validated_receipt|ADM-002|requests|handle__adm_002__update_action_draft__requests
previewActionDraft@CAS-002.next|preview-action-draft--next|view_model.sections.next.selected_target|view_model.sections.next.forms.preview_action_draft__next|request_context.review_console_session|action_result.preview_action_draft__next.validated_receipt|CAS-002|next|handle__cas_002__preview_action_draft__next
previewActionDraft@CAS-006.editor|preview-action-draft--editor|view_model.sections.editor.selected_target|view_model.sections.editor.forms.preview_action_draft__editor|request_context.review_console_session|action_result.preview_action_draft__editor.validated_receipt|CAS-006|editor|handle__cas_006__preview_action_draft__editor
previewActionDraft@CAS-007.board|preview-action-draft--board|view_model.sections.board.selected_target|view_model.sections.board.forms.preview_action_draft__board|request_context.review_console_session|action_result.preview_action_draft__board.validated_receipt|CAS-007|board|handle__cas_007__preview_action_draft__board
previewActionDraft@CAS-009.preview|preview-action-draft--preview|view_model.sections.preview.selected_target|view_model.sections.preview.forms.preview_action_draft__preview|request_context.review_console_session|action_result.preview_action_draft__preview.validated_receipt|CAS-009|preview|handle__cas_009__preview_action_draft__preview
previewActionDraft@CAS-011.decisions|preview-action-draft--decisions|view_model.sections.decisions.selected_target|view_model.sections.decisions.forms.preview_action_draft__decisions|request_context.review_console_session|action_result.preview_action_draft__decisions.validated_receipt|CAS-011|decisions|handle__cas_011__preview_action_draft__decisions
previewActionDraft@CAS-015.impact|preview-action-draft--impact|view_model.sections.impact.selected_target|view_model.sections.impact.forms.preview_action_draft__impact|request_context.review_console_session|action_result.preview_action_draft__impact.validated_receipt|CAS-015|impact|handle__cas_015__preview_action_draft__impact
previewActionDraft@RULE-004.impact|preview-action-draft--impact|view_model.sections.impact.selected_target|view_model.sections.impact.forms.preview_action_draft__impact|request_context.review_console_session|action_result.preview_action_draft__impact.validated_receipt|RULE-004|impact|handle__rule_004__preview_action_draft__impact
previewActionDraft@REV-003.gates|preview-action-draft--gates|view_model.sections.gates.selected_target|view_model.sections.gates.forms.preview_action_draft__gates|request_context.review_console_session|action_result.preview_action_draft__gates.validated_receipt|REV-003|gates|handle__rev_003__preview_action_draft__gates
previewActionDraft@OPS-005.status|preview-action-draft--status|view_model.sections.status.selected_target|view_model.sections.status.forms.preview_action_draft__status|request_context.review_console_session|action_result.preview_action_draft__status.validated_receipt|OPS-005|status|handle__ops_005__preview_action_draft__status
previewActionDraft@OPS-006.impact|preview-action-draft--impact|view_model.sections.impact.selected_target|view_model.sections.impact.forms.preview_action_draft__impact|request_context.review_console_session|action_result.preview_action_draft__impact.validated_receipt|OPS-006|impact|handle__ops_006__preview_action_draft__impact
previewActionDraft@ADM-002.conflicts|preview-action-draft--conflicts|view_model.sections.conflicts.selected_target|view_model.sections.conflicts.forms.preview_action_draft__conflicts|request_context.review_console_session|action_result.preview_action_draft__conflicts.validated_receipt|ADM-002|conflicts|handle__adm_002__preview_action_draft__conflicts
submitActionForReview@CAS-002.next|submit-action-for-review--next|view_model.sections.next.selected_target|view_model.sections.next.forms.submit_action_for_review__next|request_context.review_console_session|action_result.submit_action_for_review__next.validated_receipt|CAS-002|next|handle__cas_002__submit_action_for_review__next
submitActionForReview@CAS-006.editor|submit-action-for-review--editor|view_model.sections.editor.selected_target|view_model.sections.editor.forms.submit_action_for_review__editor|request_context.review_console_session|action_result.submit_action_for_review__editor.validated_receipt|CAS-006|editor|handle__cas_006__submit_action_for_review__editor
submitActionForReview@CAS-007.board|submit-action-for-review--board|view_model.sections.board.selected_target|view_model.sections.board.forms.submit_action_for_review__board|request_context.review_console_session|action_result.submit_action_for_review__board.validated_receipt|CAS-007|board|handle__cas_007__submit_action_for_review__board
submitActionForReview@CAS-009.gate|submit-action-for-review--gate|view_model.sections.gate.selected_target|view_model.sections.gate.forms.submit_action_for_review__gate|request_context.review_console_session|action_result.submit_action_for_review__gate.validated_receipt|CAS-009|gate|handle__cas_009__submit_action_for_review__gate
submitActionForReview@CAS-011.decisions|submit-action-for-review--decisions|view_model.sections.decisions.selected_target|view_model.sections.decisions.forms.submit_action_for_review__decisions|request_context.review_console_session|action_result.submit_action_for_review__decisions.validated_receipt|CAS-011|decisions|handle__cas_011__submit_action_for_review__decisions
submitActionForReview@CAS-015.reviews|submit-action-for-review--reviews|view_model.sections.reviews.selected_target|view_model.sections.reviews.forms.submit_action_for_review__reviews|request_context.review_console_session|action_result.submit_action_for_review__reviews.validated_receipt|CAS-015|reviews|handle__cas_015__submit_action_for_review__reviews
submitActionForReview@RULE-004.approval|submit-action-for-review--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.submit_action_for_review__approval|request_context.review_console_session|action_result.submit_action_for_review__approval.validated_receipt|RULE-004|approval|handle__rule_004__submit_action_for_review__approval
submitActionForReview@REV-003.gates|submit-action-for-review--gates|view_model.sections.gates.selected_target|view_model.sections.gates.forms.submit_action_for_review__gates|request_context.review_console_session|action_result.submit_action_for_review__gates.validated_receipt|REV-003|gates|handle__rev_003__submit_action_for_review__gates
submitActionForReview@OPS-005.status|submit-action-for-review--status|view_model.sections.status.selected_target|view_model.sections.status.forms.submit_action_for_review__status|request_context.review_console_session|action_result.submit_action_for_review__status.validated_receipt|OPS-005|status|handle__ops_005__submit_action_for_review__status
submitActionForReview@OPS-006.approval|submit-action-for-review--approval|view_model.sections.approval.selected_target|view_model.sections.approval.forms.submit_action_for_review__approval|request_context.review_console_session|action_result.submit_action_for_review__approval.validated_receipt|OPS-006|approval|handle__ops_006__submit_action_for_review__approval
submitActionForReview@ADM-002.requests|submit-action-for-review--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.submit_action_for_review__requests|request_context.review_console_session|action_result.submit_action_for_review__requests.validated_receipt|ADM-002|requests|handle__adm_002__submit_action_for_review__requests
claimActionReview@INT-002.handoff|claim-action-review--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.claim_action_review__handoff|request_context.review_console_session|action_result.claim_action_review__handoff.validated_receipt|INT-002|handoff|handle__int_002__claim_action_review__handoff
submitActionDecision@INT-002.handoff|submit-action-decision--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.submit_action_decision__handoff|request_context.review_console_session|action_result.submit_action_decision__handoff.validated_receipt|INT-002|handoff|handle__int_002__submit_action_decision__handoff
cancelActionExecution@OPS-003.recovery|cancel-action-execution--recovery|view_model.sections.recovery.selected_target|view_model.sections.recovery.forms.cancel_action_execution__recovery|request_context.review_console_session|action_result.cancel_action_execution__recovery.validated_receipt|OPS-003|recovery|handle__ops_003__cancel_action_execution__recovery
retryActionExecution@OPS-003.recovery|retry-action-execution--recovery|view_model.sections.recovery.selected_target|view_model.sections.recovery.forms.retry_action_execution__recovery|request_context.review_console_session|action_result.retry_action_execution__recovery.validated_receipt|OPS-003|recovery|handle__ops_003__retry_action_execution__recovery
releaseLegalHold@REV-002.risks|release-legal-hold--risks|view_model.sections.risks.selected_target|view_model.sections.risks.forms.release_legal_hold__risks|request_context.review_console_session|action_result.release_legal_hold__risks.validated_receipt|REV-002|risks|handle__rev_002__release_legal_hold__risks
releaseLegalHold@REV-002.decision|release-legal-hold--decision|view_model.sections.decision.selected_target|view_model.sections.decision.forms.release_legal_hold__decision|request_context.review_console_session|action_result.release_legal_hold__decision.validated_receipt|REV-002|risks|handle__rev_002__release_legal_hold__decision
createResponseAppeal@RSP-006.next|create-response-appeal--next|view_model.sections.next.selected_target|view_model.sections.next.forms.create_response_appeal__next|request_context.response_scoped_session|action_result.create_response_appeal__next.validated_receipt|RSP-006|receipt|handle__rsp_006__create_response_appeal__next
reconcileCommunicationDelivery@CAS-008.timeline|reconcile-communication-delivery--timeline|view_model.sections.timeline.selected_target|view_model.sections.timeline.forms.reconcile_communication_delivery__timeline|request_context.review_console_session|action_result.reconcile_communication_delivery__timeline.validated_receipt|CAS-008|timeline|handle__cas_008__reconcile_communication_delivery__timeline
reconcileCommunicationDelivery@OPS-005.incidents|reconcile-communication-delivery--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.reconcile_communication_delivery__incidents|request_context.review_console_session|action_result.reconcile_communication_delivery__incidents.validated_receipt|OPS-005|incidents|handle__ops_005__reconcile_communication_delivery__incidents
cancelCommunicationDelivery@CAS-008.timeline|cancel-communication-delivery--timeline|view_model.sections.timeline.selected_target|view_model.sections.timeline.forms.cancel_communication_delivery__timeline|request_context.review_console_session|action_result.cancel_communication_delivery__timeline.validated_receipt|CAS-008|timeline|handle__cas_008__cancel_communication_delivery__timeline
cancelCommunicationDelivery@OPS-005.incidents|cancel-communication-delivery--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.cancel_communication_delivery__incidents|request_context.review_console_session|action_result.cancel_communication_delivery__incidents.validated_receipt|OPS-005|incidents|handle__ops_005__cancel_communication_delivery__incidents
triageIncident@OPS-001.incidents|triage-incident--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.triage_incident__incidents|request_context.review_console_session|action_result.triage_incident__incidents.validated_receipt|OPS-001|incidents|handle__ops_001__triage_incident__incidents
containIncident@OPS-001.incidents|contain-incident--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.contain_incident__incidents|request_context.review_console_session|action_result.contain_incident__incidents.validated_receipt|OPS-001|incidents|handle__ops_001__contain_incident__incidents
startIncidentRecovery@OPS-001.incidents|start-incident-recovery--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.start_incident_recovery__incidents|request_context.review_console_session|action_result.start_incident_recovery__incidents.validated_receipt|OPS-001|incidents|handle__ops_001__start_incident_recovery__incidents
resolveIncident@OPS-001.incidents|resolve-incident--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.resolve_incident__incidents|request_context.review_console_session|action_result.resolve_incident__incidents.validated_receipt|OPS-001|incidents|handle__ops_001__resolve_incident__incidents
closeIncidentPostmortem@OPS-001.incidents|close-incident-postmortem--incidents|view_model.sections.incidents.selected_target|view_model.sections.incidents.forms.close_incident_postmortem__incidents|request_context.review_console_session|action_result.close_incident_postmortem__incidents.validated_receipt|OPS-001|incidents|handle__ops_001__close_incident_postmortem__incidents
transitionResponseAppeal@COR-001.requests|transition-response-appeal--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.transition_response_appeal__requests|request_context.review_console_session|action_result.transition_response_appeal__requests.validated_receipt|COR-001|requests|handle__cor_001__transition_response_appeal__requests
decideResponseExtension@CAS-008.requests|decide-response-extension--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.decide_response_extension__requests|request_context.review_console_session|action_result.decide_response_extension__requests.validated_receipt|CAS-008|requests|handle__cas_008__decide_response_extension__requests
decideResponseExtension@CAS-008.timeline|decide-response-extension--timeline|view_model.sections.timeline.selected_target|view_model.sections.timeline.forms.decide_response_extension__timeline|request_context.review_console_session|action_result.decide_response_extension__timeline.validated_receipt|CAS-008|requests|handle__cas_008__decide_response_extension__timeline
transitionRetentionRequest@COR-001.requests|transition-retention-request--requests|view_model.sections.requests.selected_target|view_model.sections.requests.forms.transition_retention_request__requests|request_context.review_console_session|action_result.transition_retention_request__requests.validated_receipt|COR-001|requests|handle__cor_001__transition_retention_request__requests
requestCommunicationEndpointLink@PUB-030.delivery|request-communication-endpoint-link--delivery|view_model.sections.delivery.selected_target|view_model.sections.delivery.forms.request_communication_endpoint_link__delivery|request_context.public_proof_session|action_result.request_communication_endpoint_link__delivery.validated_receipt|PUB-030|delivery|handle__pub_030__request_communication_endpoint_link__delivery
verifyCommunicationEndpointLink@PUB-030.delivery|verify-communication-endpoint-link--delivery|view_model.sections.delivery.selected_target|view_model.sections.delivery.forms.verify_communication_endpoint_link__delivery|request_context.public_proof_session|action_result.verify_communication_endpoint_link__delivery.validated_receipt|PUB-030|delivery|handle__pub_030__verify_communication_endpoint_link__delivery
unlinkCommunicationEndpoint@PUB-030.delivery|unlink-communication-endpoint--delivery|view_model.sections.delivery.selected_target|view_model.sections.delivery.forms.unlink_communication_endpoint__delivery|request_context.public_proof_session|action_result.unlink_communication_endpoint__delivery.validated_receipt|PUB-030|delivery|handle__pub_030__unlink_communication_endpoint__delivery
unlinkCommunicationEndpoint@PUB-030.unsubscribe|unlink-communication-endpoint--unsubscribe|view_model.sections.unsubscribe.selected_target|view_model.sections.unsubscribe.forms.unlink_communication_endpoint__unsubscribe|request_context.public_proof_session|action_result.unlink_communication_endpoint__unsubscribe.validated_receipt|PUB-030|delivery|handle__pub_030__unlink_communication_endpoint__unsubscribe
createPrivacyRequest@PUB-031.rights|create-privacy-request--rights|view_model.sections.rights.selected_target|view_model.sections.rights.forms.create_privacy_request__rights|request_context.public_proof_session|action_result.create_privacy_request__rights.validated_receipt|PUB-031|rights|handle__pub_031__create_privacy_request__rights
exchangePrivacyRequestReceiptToken@PUB-031.rights|exchange-privacy-request-receipt-token--rights|view_model.sections.rights.selected_target|view_model.sections.rights.forms.exchange_privacy_request_receipt_token__rights|request_context.public_proof_session|action_result.exchange_privacy_request_receipt_token__rights.validated_receipt|PUB-031|rights|handle__pub_031__exchange_privacy_request_receipt_token__rights
declareConflict@REV-002.decision|declare-conflict--decision|view_model.sections.decision.selected_target|view_model.sections.decision.forms.declare_conflict__decision|request_context.review_console_session|action_result.declare_conflict__decision.validated_receipt|REV-002|decision|handle__rev_002__declare_conflict__decision
declareConflict@ADM-002.conflicts|declare-conflict--conflicts|view_model.sections.conflicts.selected_target|view_model.sections.conflicts.forms.declare_conflict__conflicts|request_context.review_console_session|action_result.declare_conflict__conflicts.validated_receipt|ADM-002|conflicts|handle__adm_002__declare_conflict__conflicts
withdrawConflict@ADM-002.conflicts|withdraw-conflict--conflicts|view_model.sections.conflicts.selected_target|view_model.sections.conflicts.forms.withdraw_conflict__conflicts|request_context.review_console_session|action_result.withdraw_conflict__conflicts.validated_receipt|ADM-002|conflicts|handle__adm_002__withdraw_conflict__conflicts
withdrawActionProposal@INT-002.handoff|withdraw-action-proposal--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.withdraw_action_proposal__handoff|request_context.review_console_session|action_result.withdraw_action_proposal__handoff.validated_receipt|INT-002|handoff|handle__int_002__withdraw_action_proposal__handoff
withdrawActionDecision@INT-002.handoff|withdraw-action-decision--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.withdraw_action_decision__handoff|request_context.review_console_session|action_result.withdraw_action_decision__handoff.validated_receipt|INT-002|handoff|handle__int_002__withdraw_action_decision__handoff
promoteResearchArtifactToEvidence@CAS-011.citations|promote-research-artifact-to-evidence--citations|view_model.sections.citations.selected_target|view_model.sections.citations.forms.promote_research_artifact_to_evidence__citations|request_context.review_console_session|action_result.promote_research_artifact_to_evidence__citations.validated_receipt|CAS-005|source|handle__cas_011__promote_research_artifact_to_evidence__citations
cancelAgentRun@CAS-010.runs|cancel-agent-run--runs|view_model.sections.runs.selected_target|view_model.sections.runs.forms.cancel_agent_run__runs|request_context.review_console_session|action_result.cancel_agent_run__runs.validated_receipt|CAS-010|runs|handle__cas_010__cancel_agent_run__runs
cancelAgentRun@CAS-011.model|cancel-agent-run--model|view_model.sections.model.selected_target|view_model.sections.model.forms.cancel_agent_run__model|request_context.review_console_session|action_result.cancel_agent_run__model.validated_receipt|CAS-011|model|handle__cas_011__cancel_agent_run__model
decideJourneyHandoff@INT-002.handoff|decide-journey-handoff--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.decide_journey_handoff__handoff|request_context.review_console_session|action_result.decide_journey_handoff__handoff.validated_receipt|INT-002|handoff|handle__int_002__decide_journey_handoff__handoff
recordSupplierIdentityResolution@INT-002.handoff|record-supplier-identity-resolution--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.record_supplier_identity_resolution__handoff|request_context.review_console_session|action_result.record_supplier_identity_resolution__handoff.validated_receipt|INT-002|handoff|handle__int_002__record_supplier_identity_resolution__handoff
recordSupplierRelationshipAssertion@INT-002.handoff|record-supplier-relationship-assertion--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.record_supplier_relationship_assertion__handoff|request_context.review_console_session|action_result.record_supplier_relationship_assertion__handoff.validated_receipt|INT-002|handoff|handle__int_002__record_supplier_relationship_assertion__handoff
decideSupplierRelationshipAssertion@INT-002.handoff|decide-supplier-relationship-assertion--handoff|view_model.sections.handoff.selected_target|view_model.sections.handoff.forms.decide_supplier_relationship_assertion__handoff|request_context.review_console_session|action_result.decide_supplier_relationship_assertion__handoff.validated_receipt|INT-002|handoff|handle__int_002__decide_supplier_relationship_assertion__handoff
""",
    9,
)


PRIORITY_SCREEN_REFINEMENTS: dict[str, dict[str, Any]] = {
    "PUB-004": {
        "primary_action_id": "open-evidence",
        "primary_consequence": "선택한 핵심 문장의 공개 버전에 고정된 근거, 원문 위치, 변환 이력과 반대 근거를 한 상세 패널에서 연다.",
        "required_additional_actions": [
            {
                "action_id": "reproduce-calculation",
                "label": "계산 재현하기",
                "kind": "NAVIGATION",
                "destination_screen_id": "PUB-006",
                "required_bindings": {"caseSlug": "current_case.caseSlug"},
                "focus_test_id": "pub_006__heading",
            },
            {
                "action_id": "open-fixed-revision",
                "label": "고정 revision 보기",
                "kind": "NAVIGATION",
                "destination_screen_id": "PUB-005",
                "required_bindings": {
                    "caseSlug": "current_case.caseSlug",
                    "revision": "selected_revision.revision",
                },
                "focus_test_id": "pub_005__heading",
            },
        ],
    },
    "PUB-006": {
        "primary_action_id": "download-json",
        "primary_consequence": "현재 공개 버전의 규칙·입력 무결성 값·비교군·제외 사유·파일 검증값·이용 조건을 포함한 재현 묶음을 저장한다.",
        "exact_section_source_bindings": {
            "summary": [
                "getCaseReproducibility.caseSlug",
                "getCaseReproducibility.ruleId",
                "getCaseReproducibility.ruleVersion",
                "getCaseReproducibility.target",
                "getCaseReproducibility.result",
            ],
            "inputs": [
                "getCaseReproducibility.inputDigest",
                "getCaseReproducibility.resultDigest",
                "CaseReproducibilityV2.datasetSnapshotId",
                "CaseReproducibilityV2.datasetWatermark",
            ],
            "cohort": [
                "getCaseReproducibility.includedCohort",
                "getCaseReproducibility.excludedCohort",
                "CaseReproducibilityV2.exclusionReasons",
            ],
            "formula": [
                "getCaseReproducibility.formula",
                "getCaseReproducibility.roundingPolicy",
                "CaseReproducibilityV2.unit",
            ],
            "download": [
                "downloadCaseReproducibility.binary",
                "ReproducibilityDownloadV2.contentSha256",
                "ReproducibilityDownloadV2.mediaType",
                "ReproducibilityDownloadV2.license",
                "ReproducibilityDownloadV2.correctionContext",
            ],
            "limitations": ["getCaseReproducibility.limitations", "CaseReproducibilityV2.rightsLimitations"],
        },
        "api_schema_dependencies": [
            "CaseReproducibilityV2 must add datasetSnapshotId, datasetWatermark, exclusionReasons, unit and rightsLimitations.",
            "ReproducibilityDownloadV2 must replace an opaque binary-only response with contentSha256, mediaType, license and correctionContext metadata.",
        ],
        "required_additional_actions": [
            {
                "action_id": "view-correction-context",
                "label": "정정 맥락 확인하기",
                "kind": "NAVIGATION",
                "destination_screen_id": "PUB-018",
                "required_bindings": {},
                "focus_test_id": "pub_018__heading",
            }
        ],
    },
    "PUB-005": {
        "primary_action_id": "view-latest",
        "primary_consequence": "현재 공개 버전과 이 고정 버전의 차이를 유지한 채 최신 사건 화면으로 이동한다.",
        "required_additional_actions": [
            {
                "action_id": "reproduce-fixed-revision",
                "label": "이 revision 계산 재현하기",
                "kind": "NAVIGATION",
                "destination_screen_id": "PUB-006",
                "required_bindings": {
                    "caseSlug": "current_revision.caseSlug",
                    "revision": "current_revision.revision",
                },
                "focus_test_id": "pub_006__heading",
            }
        ],
    },
    "RSP-005": {
        "primary_action_id": "submit",
        "primary_consequence": "모든 답변·검사 완료 첨부·세분화된 공개 동의·제출 권한을 한 번 더 보여준 뒤 바뀌지 않는 제출 기록으로 접수한다.",
        "exact_section_source_bindings": {
            "answers": ["getResponseSubmissionPreview.answers", "getResponseSubmissionPreview.warnings"],
            "attachments": ["getResponseSubmissionPreview.attachments"],
            "consent": ["getResponseSubmissionPreview.publicationConsent"],
            "authority": ["getResponseSubmissionPreview.request", "ResponseSubmissionPreviewV2.authorityAttestation"],
            "consequence": ["getResponseSubmissionPreview.submissionDigest", "submitResponse.receiptSession"],
        },
        "state_dependent_primary_action": [
            {
                "condition_id": "ready-to-submit",
                "when": {"primary_state": "saved", "blocking_codes": [], "previewDigestCurrent": True},
                "action_id": "submit",
                "enabled": True,
                "focus_test_id": "rsp_005__action__submit",
            },
            {
                "condition_id": "required-answer-missing",
                "when": {"special_state": "missing-required-answer"},
                "action_id": "change-answer",
                "enabled": True,
                "focus_test_id": "rsp_005__error_summary",
            },
            {
                "condition_id": "attachment-scan-pending",
                "when": {"special_state": "scan-pending"},
                "action_id": "change-files",
                "enabled": True,
                "focus_test_id": "rsp_005__section__attachments",
            },
            {
                "condition_id": "consent-missing",
                "when": {"primary_state": "validation-error", "blocking_code": "CONSENT_REQUIRED"},
                "action_id": "change-answer",
                "enabled": True,
                "focus_test_id": "rsp_005__section__consent",
            },
            {
                "condition_id": "authority-missing",
                "when": {"primary_state": "validation-error", "blocking_code": "AUTHORITY_ATTESTATION_REQUIRED"},
                "action_id": "change-answer",
                "enabled": True,
                "focus_test_id": "rsp_005__section__authority",
            },
            {
                "condition_id": "preview-stale",
                "when": {"primary_state": "draft", "previewDigestCurrent": False},
                "action_id": "refresh-preview",
                "enabled": True,
                "focus_test_id": "rsp_005__section__consequence",
            },
            {
                "condition_id": "submit-conflict",
                "when": {"special_state": "submit-conflict"},
                "action_id": "compare-latest",
                "enabled": True,
                "focus_test_id": "rsp_005__special__submit_conflict__heading",
            },
            {
                "condition_id": "offline",
                "when": {"primary_state": "offline"},
                "action_id": "submit",
                "enabled": False,
                "focus_test_id": None,
            },
            {
                "condition_id": "submitting",
                "when": {"primary_state": "saving", "commandPhase": "SUBMIT"},
                "action_id": "submit",
                "enabled": False,
                "focus_test_id": None,
            },
            {
                "condition_id": "duplicate-submit",
                "when": {"special_state": "duplicate-submit"},
                "action_id": "open-existing-receipt",
                "enabled": True,
                "focus_test_id": "rsp_006__section__receipt",
            },
        ],
        "api_schema_dependencies": [
            "ResponseSubmissionPreviewV2 must expose a typed authorityAttestation separate from consent and answers.",
            "The submission BFF must expose stale-draft and authority-missing signals without leaking the scoped token.",
        ],
        "component_overrides": {
            "answers": {"component": "CheckAnswers", "variant": "response"},
            "attachments": {"component": "FileUploadQueue", "variant": "response"},
            "consent": {"component": "GuidedFormSection", "variant": "response"},
            "authority": {"component": "GuidedFormSection", "variant": "response"},
            "consequence": {"component": "GuidedFormSection", "variant": "response"},
        },
        "post_success": {
            "operation_id": "submitResponse",
            "destination_screen_id": "RSP-006",
            "destination_section_id": "receipt",
            "focus_test_id": "rsp_006__section__receipt",
        },
    },
    "RSP-006": {
        "primary_action_id": "download-receipt",
        "primary_consequence": "제출 번호·시각·항목 무결성 값·동의·다음 절차가 포함된 영수증을 저장한다.",
        "conditional_action": {
            "action_id": "create-response-appeal",
            "operation_id": "createResponseAppeal",
            "visible_when": "view_model.appeal.eligible == true",
            "section_id": "next",
        },
        "appeal_contract": {
            "session_authority": "APPEAL_CREATE response-receipt scoped HttpOnly session",
            "form_field_bindings": {
                "expectedReceiptVersion": "view_model.receipt.version",
                "reasonCode": "appeal_form.reasonCode",
                "requestedOutcome": "appeal_form.requestedOutcome",
                "statement": "appeal_form.statement",
                "supportingAttachmentIds": "appeal_form.completedAttachments[].attachmentId",
                "attestation": "appeal_form.attestation",
                "privacyConsent": "appeal_form.privacyConsent",
            },
            "create_operation": "createResponseAppeal",
            "receipt_schema": "ResponseAppealReceiptV1",
            "status_operation": "getResponseAppeal",
            "status_identity_binding": "createResponseAppeal.receipt.appeal.appealId",
            "terminal_states": ["RESOLVED", "REJECTED", "DUPLICATE", "WITHDRAWN"],
            "safe_return_focus_test_id": "rsp_006__section__next",
        },
        "component_overrides": {
            "receipt": {"component": "DecisionReceipt", "variant": "response"},
            "summary": {"component": "CheckAnswers", "variant": "response"},
            "next": {"component": "GuidedFormSection", "variant": "response"},
        },
    },
    "CAS-011": {
        "primary_action_id": "accept-suggestion",
        "primary_consequence": "선택한 구조화된 제안의 근거·반대 근거·자료 조사·수신자·내용·비용·위험을 확인하고 사람의 결정만 기록한다.",
        "required_view_model_types": [
            "AgentRunSummaryV1",
            "ProviderTurnSummaryV1",
            "ToolCallSummaryV1",
            "AgentProposalReviewV1",
            "CitationVerificationSummaryV1",
            "ProvenanceGraphVmV1",
        ],
        "agent_run_detail_field_set": {
            "identity": ["runId", "caseId", "agentKind", "purpose", "runVersion", "startedAt", "completedAt", "state"],
            "inputs": ["sourceAssetRevisionIds", "evidenceSegmentIds", "inputDigests", "rights", "datasetSnapshotIds"],
            "activity": ["providerTurns[].turnId", "providerTurns[].modelPolicy", "toolCalls[].toolKind", "toolCalls[].sourceUseReceiptId", "toolCalls[].resultDigest"],
            "findings": ["findings[].findingId", "findings[].statement", "findings[].confidenceClass", "findings[].citationIds"],
            "counter_evidence": ["counterEvidence[].evidenceId", "counterEvidence[].effect", "counterEvidence[].citationId"],
            "unknowns": ["unknowns[].question", "unknowns[].materiality", "unknowns[].nextInvestigationTask"],
            "proposals": ["proposals[].proposalId", "proposals[].proposalVersion", "proposals[].proposalDigest", "proposals[].target", "proposals[].effect", "proposals[].recipient", "proposals[].channel", "proposals[].exactContent", "proposals[].cost", "proposals[].risk", "proposals[].requiredApproval"],
            "cost": ["providerUsage", "allocatedCost", "budgetEnvelope", "budgetRemaining"],
        },
        "forbidden_fields": ["opaqueOutputString", "rawJson", "hiddenChainOfThought"],
        "component_overrides": {
            "output": {"component": "AgentSuggestionPanel", "variant": "detail"},
            "citations": {"component": "EvidenceLedger", "variant": "internal"},
            "safety": {"component": "SensitiveDataNotice", "variant": "restricted"},
            "decisions": {"component": "AgentSuggestionPanel", "variant": "diff"},
            "cost": {"component": "MetricWithContext", "variant": "single"},
        },
        "api_schema_dependencies": [
            "getAgentRun must replace the v13 opaque output/data envelope with AgentRunDetailV2 and the six required closed child collections.",
            "CitationVerificationSummaryV1 must carry authorized asset revision, canonical locator, rights, stale and hash-mismatch state.",
        ],
    },
    "REV-002": {
        "primary_action_id": "request-changes",
        "primary_consequence": "고정 검토본의 핵심 문장·근거·반대 근거·소명·독립성·변경 차이를 바꾸지 않고 이유가 구조화된 결정을 제출한다.",
        "post_success_by_decision": {
            "APPROVE": {
                "destination_screen_id": "REV-003",
                "focus_test_id": "rev_003__heading",
            },
            "CHANGES_REQUIRED": {
                "destination_screen_id": "CAS-013",
                "focus_test_id": "cas_013__section__tasks",
            },
        },
        "exact_section_source_bindings": {
            "identity": ["getReviewSnapshot.snapshotId", "getReviewSnapshot.caseId", "getReviewSnapshot.caseVersion", "getReviewSnapshot.snapshotHash", "getReviewSnapshot.createdAt", "getReviewSnapshot.createdBy"],
            "preview": ["getReviewSnapshot.claims", "getReviewSnapshot.responses"],
            "matrix": ["getReviewSnapshot.claims", "getReviewSnapshot.evidence", "getReviewSnapshot.responses"],
            "diff": ["getReviewSnapshot.diffFromCurrent"],
            "risks": ["getReviewSnapshot.automatedGates", "getReviewSnapshot.independence", "getReviewSnapshot.unresolvedBlockers"],
            "decision": ["submitReview.expectedSnapshotHash", "submitReview.expectedCaseVersion", "submitReview.decision", "submitReview.reason"],
        },
        "component_overrides": {
            "matrix": {"component": "EvidenceLedger", "variant": "review"},
            "risks": {"component": "GateChecklist", "variant": "publication"},
            "decision": {"component": "DecisionReviewPanel", "variant": "review"},
        },
    },
    "REV-003": {
        "primary_action_id": "publish",
        "primary_consequence": "최신 검증 조건을 서버에서 다시 계산한 뒤 정확한 검토본만 새 공개 버전으로 게시하고 공개 화면 반영·알림·공개 확인 영수증을 남긴다.",
        "post_success": {
            "operation_id": "publishCase",
            "destination_screen_id": "PUB-004",
            "destination_section_id": "status",
            "focus_test_id": "pub_004__section__status",
        },
        "publication_receipt_requirements": [
            "publicationId",
            "publicationRevision",
            "snapshotHash",
            "projectionState",
            "notificationState",
            "publicSmokeReceiptId",
            "auditEventId",
        ],
        "api_schema_dependencies": [
            "getPublishConfirmation and getPublicationReceipt generic data envelopes must become closed typed schemas with current gate and public-smoke fields.",
        ],
    },
    "OPS-006": {
        "primary_action_id": "activate",
        "primary_consequence": "선택한 기능 범위·사용자 영향·안전 대체 경로·만료·복구 기준을 고정하고 필요한 직무분리 승인 뒤 중지한다.",
        "required_preview_fields": [
            "switchKind",
            "scope",
            "affectedUsers",
            "affectedJobs",
            "safeFallback",
            "expiresAt",
            "recoveryCriteria",
            "approvals",
        ],
        "legacy_direct_effect_fence": "activateKillSwitch, deactivateKillSwitch and extendKillSwitch may create only a proposal until quorum produces an execution authorization receipt.",
        "receipt_requirements": ["proposalDigest", "authorizationReceiptId", "switchRevision", "scope", "effectiveAt", "expiresAt", "safeFallback", "verificationTaskId"],
        "component_overrides": {
            "active": {"component": "OperationsStatusPanel", "variant": "service-health"},
            "impact": {"component": "OperationsStatusPanel", "variant": "internal-incident"},
            "approval": {"component": "DecisionReviewPanel", "variant": "review"},
        },
    },
}


JOURNEY_VISIBLE_ACTIONS: list[dict[str, Any]] = [
    {
        "screen_id": "CAS-004",
        "section_id": "gaps",
        "action_id": "start-agent-research",
        "label": "AI 조사로 근거 공백 확인하기",
        "destination_screen_id": "CAS-010",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-011",
        "section_id": "citations",
        "action_id": "select-promotion-candidate",
        "label": "근거 승격 후보 선택하기",
        "destination_screen_id": "CAS-011",
        "bindings": {
            "caseId": "current_run.caseId",
            "runId": "current_run.runId",
        },
    },
    {
        "screen_id": "CAS-005",
        "section_id": "relationships",
        "action_id": "open-evidence-matrix",
        "label": "근거 행렬에서 확인하기",
        "destination_screen_id": "CAS-004",
        "bindings": {"caseId": "current_evidence.caseId"},
    },
    {
        "screen_id": "CAS-002",
        "section_id": "next",
        "action_id": "open-agent-research",
        "label": "AI 조사 시작하기",
        "destination_screen_id": "CAS-010",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-002",
        "section_id": "next",
        "action_id": "open-evidence-matrix",
        "label": "근거 행렬 직접 검토하기",
        "destination_screen_id": "CAS-004",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "OPS-004",
        "section_id": "changes",
        "action_id": "open-paid-workflow-audit",
        "label": "유료 가치 감사 체인 확인하기",
        "destination_screen_id": "AUD-001",
        "bindings": {},
    },
    {
        "screen_id": "PUB-002",
        "section_id": "results",
        "action_id": "open-case-result",
        "label": "사건 결과 열기",
        "destination_screen_id": "PUB-004",
        "bindings": {"caseSlug": "selected_result.caseSlug"},
    },
    {
        "screen_id": "CAS-002",
        "section_id": "next",
        "action_id": "open-linked-signals",
        "label": "연결 신호 검토하기",
        "destination_screen_id": "CAS-003",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-003",
        "section_id": "signals",
        "action_id": "open-evidence-matrix",
        "label": "근거 행렬 검토하기",
        "destination_screen_id": "CAS-004",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-005",
        "section_id": "relationships",
        "action_id": "open-hypotheses",
        "label": "연결 가설 검토하기",
        "destination_screen_id": "CAS-007",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-007",
        "section_id": "board",
        "action_id": "open-claims",
        "label": "공개 문장 작성하기",
        "destination_screen_id": "CAS-006",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-006",
        "section_id": "relationships",
        "action_id": "open-responses",
        "label": "소명과 대조하기",
        "destination_screen_id": "CAS-008",
        "bindings": {"caseId": "current_case.caseId"},
    },
    {
        "screen_id": "CAS-008",
        "section_id": "verification",
        "action_id": "open-review-readiness",
        "label": "검토 준비도 확인하기",
        "destination_screen_id": "CAS-013",
        "bindings": {"caseId": "current_case.caseId"},
    },
]



# Download controls in the base catalog predate operation_id on local-only
# actions; bind the exact control here instead of accepting an operation-only
# journey edge with no user-visible source.
JOURNEY_OPERATION_ACTION_OVERRIDES: dict[tuple[str, str], list[str]] = {
    ("PUB-006", "downloadCaseReproducibility"): ["PUB-006.download-json"],
}


def snake_screen(screen_id: str) -> str:
    return screen_id.lower().replace("-", "_")


def kebab_operation(operation_id: str) -> str:
    chars: list[str] = []
    for char in operation_id:
        if char.isupper():
            chars.extend(("-", char.lower()))
        else:
            chars.append(char)
    return "".join(chars).lstrip("-")


def schema_fields(schema_name: str, resources: dict[str, Any]) -> list[dict[str, Any]]:
    schema = resources["schemas"].get(schema_name)
    if not isinstance(schema, dict):
        return []
    required = set(schema.get("required", schema.get("fields", {}).keys()))
    return [
        {"name": name, "type": field_type, "required": name in required}
        for name, field_type in schema.get("fields", {}).items()
    ]


SERVER_ONLY_BROWSER_FIELD_NAMES = {
    "accessToken",
    "actorAssertion",
    "authorization",
    "cookie",
    "credential",
    "csrfToken",
    "draftToken",
    "fencingToken",
    "managementToken",
    "nonce",
    "pendingSession",
    "proof",
    "proofToken",
    "receiptSession",
    "receiptToken",
    "refreshToken",
    "secret",
    "session",
    "sessionToken",
    "token",
}


def is_server_only_browser_field(field: dict[str, Any]) -> bool:
    """Classify bearer material by contract name/type, including compound names."""

    name = str(field.get("name", ""))
    normalized = re.sub(r"[^a-z0-9]", "", name.lower())
    field_type = str(field.get("type", "")).lower()
    exact = {re.sub(r"[^a-z0-9]", "", item.lower()) for item in SERVER_ONLY_BROWSER_FIELD_NAMES}
    return (
        normalized in exact
        or normalized.endswith(("token", "proof", "nonce", "credential", "assertion"))
        or "secret" in normalized
        or "secret-string" in field_type
    )


def split_browser_fields(
    fields: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    browser_safe: list[dict[str, Any]] = []
    server_only: list[dict[str, Any]] = []
    for field in fields:
        target = server_only if is_server_only_browser_field(field) else browser_safe
        target.append(copy.deepcopy(field))
    return browser_safe, server_only


def base_operation_contract(operation: dict[str, Any]) -> dict[str, Any]:
    request_fields = copy.deepcopy(operation.get("request_fields", []))
    response_fields = copy.deepcopy(operation.get("response_fields", []))
    browser_request, server_request = split_browser_fields(request_fields)
    browser_response, server_response = split_browser_fields(response_fields)
    return {
        "operation_id": operation["operation_id"],
        "source": "specs/ui/screen-data-contracts.yaml",
        "kind": operation.get("operation_kind", "QUERY" if operation["method"] == "GET" else "COMMAND"),
        "api": operation["api"],
        "method": operation["method"],
        "path": operation["path"],
        "request_schema": operation.get("request_schema"),
        "request_field_set": browser_request,
        "server_only_request_field_set": server_request,
        "response_schema": operation.get("response_schema"),
        "response_field_set": browser_response,
        "server_only_response_field_set": server_response,
        "browser_boundary": "BFF_PROJECTED" if server_request or server_response else "BROWSER_SAFE_PROJECTION_REQUIRED",
        "rendering_rule": "DTO 전체 렌더링 금지; 이 화면의 명시적 view-model mapper만 필요한 필드를 복사한다.",
    }


def additive_operation_metadata(
    operation: dict[str, Any], resources: dict[str, Any]
) -> dict[str, Any]:
    operation_id = operation["operation_id"]
    operation_bindings = resources.get("operation_bindings")
    if not isinstance(operation_bindings, dict):
        raise ValueError("additive resources: operation_bindings must be a mapping")
    binding = operation_bindings.get(operation_id)
    if not isinstance(binding, dict):
        raise ValueError(f"{operation_id}: missing additive external operation binding")
    if binding.get("scope") != "ADDITIVE_EXTERNAL":
        raise ValueError(f"{operation_id}: operation binding is not ADDITIVE_EXTERNAL")

    request_schemas = resources.get("request_schemas_by_operation")
    if not isinstance(request_schemas, dict):
        raise ValueError(
            "additive resources: request_schemas_by_operation must be a mapping"
        )
    request_definition = request_schemas.get(operation_id)
    if not isinstance(request_definition, dict):
        raise ValueError(f"{operation_id}: missing additive request schema definition")
    request_schema = binding.get("request_schema")
    if not isinstance(request_schema, str) or not request_schema:
        raise ValueError(f"{operation_id}: missing additive request schema binding")
    if request_definition.get("name") != request_schema:
        raise ValueError(
            f"{operation_id}: request schema definition does not match operation binding"
        )

    response_schema = binding.get("success_schema")
    if not isinstance(response_schema, str) or not response_schema:
        raise ValueError(f"{operation_id}: missing additive success schema binding")
    if operation.get("response") != response_schema:
        raise ValueError(
            f"{operation_id}: response schema does not match operation binding"
        )
    success_status = binding.get("success_status")
    if not isinstance(success_status, int) or isinstance(success_status, bool):
        raise ValueError(f"{operation_id}: missing additive integer success status")

    metadata = {
        "operation_id": operation_id,
        "scope": "ADDITIVE_EXTERNAL",
        "status": "READY",
        "api": operation.get("api"),
        "method": operation.get("method"),
        "path": operation.get("path"),
        "request_schema": request_schema,
        "response_schema": response_schema,
        "success_status": success_status,
        "operation": operation,
    }
    for field in ("api", "method", "path"):
        if not isinstance(metadata[field], str) or not metadata[field]:
            raise ValueError(f"{operation_id}: missing additive {field}")
    return metadata


def build_external_operation_catalog(
    data: dict[str, Any],
    addendum_operations: dict[str, Any],
    resources: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    base_by = unique_by_key(
        data["operations"], "operation_id", "screen data operations"
    )
    additive_by = unique_by_key(
        addendum_operations["operations"],
        "operation_id",
        "additive operations",
    )
    duplicates = sorted(set(base_by) & set(additive_by))
    if duplicates:
        raise ValueError(
            f"duplicate external operation IDs across base/additive catalogs: {duplicates}"
        )

    operation_bindings = resources.get("operation_bindings")
    if not isinstance(operation_bindings, dict):
        raise ValueError("additive resources: operation_bindings must be a mapping")
    external_binding_ids = {
        operation_id
        for operation_id, binding in operation_bindings.items()
        if isinstance(binding, dict) and binding.get("scope") == "ADDITIVE_EXTERNAL"
    }
    if external_binding_ids != set(additive_by):
        missing = sorted(set(additive_by) - external_binding_ids)
        extra = sorted(external_binding_ids - set(additive_by))
        raise ValueError(
            "additive external operation binding set mismatch: "
            f"missing={missing}, extra={extra}"
        )

    catalog: dict[str, dict[str, Any]] = {
        operation_id: {
            "operation_id": operation_id,
            "scope": "BASE",
            "status": operation.get("status"),
            "api": operation.get("api"),
            "method": operation.get("method"),
            "path": operation.get("path"),
            "request_schema": operation.get("request_schema"),
            "response_schema": operation.get("response_schema"),
            "success_status": operation.get("success_status"),
            "operation": operation,
        }
        for operation_id, operation in base_by.items()
    }
    catalog.update(
        {
            operation_id: additive_operation_metadata(operation, resources)
            for operation_id, operation in additive_by.items()
        }
    )
    return catalog


def validate_screen_data_requirement(
    screen_id: str,
    requirement: dict[str, Any],
    external_catalog: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    operation_id = requirement.get("operation_id")
    operation = external_catalog.get(operation_id)
    if operation is None:
        raise ValueError(f"{screen_id}: unknown data requirement {operation_id}")
    fields = [
        "status",
        "api",
        "method",
        "path",
        "request_schema",
        "response_schema",
    ]
    if operation["scope"] == "ADDITIVE_EXTERNAL" or "success_status" in requirement:
        fields.append("success_status")
    for field in fields:
        if requirement.get(field) != operation.get(field):
            raise ValueError(
                f"{screen_id}:{operation_id}: {field} mismatch "
                f"({requirement.get(field)!r} != {operation.get(field)!r})"
            )
    return operation


def additive_operation_contract(operation: dict[str, Any], resources: dict[str, Any]) -> dict[str, Any]:
    metadata = additive_operation_metadata(operation, resources)
    request = operation.get("request", {})
    required = set(request.get("required", []))
    request_fields = [
        {"name": name, "type": field_type, "required": name in required}
        for name, field_type in request.get("fields", {}).items()
    ]
    response_fields = schema_fields(operation.get("response", ""), resources)
    browser_request, server_request = split_browser_fields(request_fields)
    browser_response, server_response = split_browser_fields(response_fields)
    return {
        "operation_id": operation["operation_id"],
        "source": "specs/product/addendum-operation-contracts.yaml",
        "kind": operation["kind"],
        "api": operation["api"],
        "method": operation["method"],
        "path": operation["path"],
        "request_schema": metadata["request_schema"],
        "request_field_set": browser_request,
        "server_only_request_field_set": server_request,
        "response_schema": metadata["response_schema"],
        "success_status": metadata["success_status"],
        "response_field_set": browser_response,
        "server_only_response_field_set": server_response,
        "browser_boundary": "BFF_PROJECTED" if server_request or server_response else "BROWSER_SAFE_PROJECTION_REQUIRED",
        "rendering_rule": "DTO 전체 렌더링 금지; 이 화면의 명시적 view-model mapper만 필요한 필드를 복사한다.",
    }


def operation_ui_dependencies(operation: dict[str, Any]) -> list[str]:
    fields = operation["response_field_set"]
    names = {field.get("name") for field in fields if isinstance(field, dict)}
    dependencies: list[str] = []
    if not fields:
        dependencies.append(
            f"{operation['operation_id']} requires a closed non-empty response field contract before its UI can ship."
        )
    if "data" in names:
        dependencies.append(
            f"{operation['operation_id']} must replace its generic data field with a closed screen-owned projection."
        )
    if "binary" in names:
        dependencies.append(
            f"{operation['operation_id']} must provide filename, media type, byte length, checksum, rights and revision metadata beside the binary body."
        )
    secret_names = {
        field["name"] for field in operation.get("server_only_response_field_set", [])
    } | {field["name"] for field in operation.get("server_only_request_field_set", [])}
    if secret_names:
        dependencies.append(
            f"{operation['operation_id']} fields {sorted(secret_names)} are BFF/session-boundary only and must never enter the browser view-model."
        )
    return dependencies


def canonical_profile_resolution(
    screen: dict[str, Any],
    manifest_screen: dict[str, Any],
    archetype: dict[str, Any],
    profile_states: dict[str, list[str]],
) -> dict[str, Any]:
    canonical_profile = screen["state_profile"]
    canonical_states = profile_states[canonical_profile]
    manifest_states = manifest_screen["states"]
    refinement_map = MANIFEST_STATE_REFINEMENTS[canonical_profile]
    if not set(manifest_states) <= set(refinement_map):
        raise ValueError(
            f"{screen['id']}: one or more build-manifest states lack an explicit refinement"
        )
    manifest_resolution: list[dict[str, Any]] = []
    for manifest_state in manifest_states:
        mapped_states = refinement_map[manifest_state]
        if not set(mapped_states) <= set(canonical_states):
            raise ValueError(f"{screen['id']}.{manifest_state}: invalid canonical refinement")
        if not mapped_states:
            disposition = "ORTHOGONAL_ACCEPTANCE_SIGNAL"
            reason = (
                "The build-manifest word is an acceptance observation, not a primary runtime state; "
                "the canonical selector evaluates it beside exactly one primary state."
            )
        elif mapped_states == [manifest_state]:
            disposition = "DIRECT_CANONICAL_STATE"
            reason = "The build-manifest state is identical to one canonical runtime state."
        else:
            disposition = "REFINED_CANONICAL_STATES"
            reason = (
                "The build-manifest state is intentionally split so loading source, empty scope, "
                "failure recovery, or saved outcome is not collapsed."
            )
        manifest_resolution.append(
            {
                "manifest_state": manifest_state,
                "disposition": disposition,
                "canonical_states": mapped_states,
                "orthogonal_signal_path": MANIFEST_STATE_SIGNAL_PATHS[manifest_state]
                if disposition == "ORTHOGONAL_ACCEPTANCE_SIGNAL"
                else None,
                "reason": reason,
            }
        )
    default_profile = archetype["default_state_profile"]
    return {
        "canonical_profile": canonical_profile,
        "canonical_source": "specs/ui/screen-catalog.yaml#screens[].state_profile",
        "canonical_states": canonical_states,
        "selection_rule": "An explicit screen state_profile is authoritative; archetype profile is a default only.",
        "screen_specific_reason": (
            f"{screen['id']} ({screen['title']}) uses its explicit {canonical_profile} profile for "
            f"the task ‘{screen['primary_job']}’; layout archetype {screen['archetype']} does not replace it."
        ),
        "archetype_default_resolution": {
            "archetype": screen["archetype"],
            "default_profile": default_profile,
            "disposition": "MATCHES_CANONICAL"
            if default_profile == canonical_profile
            else "EXPLICIT_SCREEN_OVERRIDE",
            "reason": "The archetype profile supplies a default only; the screen-specific catalog assignment wins by the state selection contract.",
        },
        "build_manifest_resolution": {
            "manifest_states": manifest_states,
            "disposition": "GENERIC_ACCEPTANCE_VOCABULARY_REFINED",
            "state_map": manifest_resolution,
            "reason": "Build-manifest state words remain acceptance requirements but cannot collapse canonical primary-state semantics.",
        },
    }


SEMANTIC_DIMENSIONS = ("object", "state", "answer", "evidence", "unknown", "next_action")


def semantic_copy_contract(
    screen: dict[str, Any],
    section: dict[str, Any],
    dimension: str,
    primary_action: dict[str, Any],
    refinement: dict[str, Any],
) -> dict[str, Any]:
    """Return only screen-authored copy; this function writes no sentence."""

    if dimension == "object":
        return {
            "heading": screen["title"],
            "explanation": screen["primary_job"],
            "sources": ["screen-catalog.title", "screen-catalog.primary_job"],
        }
    if dimension == "answer":
        return {
            "heading": section["title"],
            "prompt": screen["user_questions"][0],
            "explanation": section["purpose"],
            "sources": ["screen-catalog.user_questions[0]", f"screen-catalog.sections.{section['id']}"],
        }
    if dimension == "unknown":
        return {
            "heading": section["title"],
            "prompts": copy.deepcopy(screen["user_questions"][1:]),
            "explanation": section["purpose"],
            "sources": ["screen-catalog.user_questions[1:]", f"screen-catalog.sections.{section['id']}"],
        }
    if dimension == "next_action":
        return {
            "heading": section["title"],
            "action_label": primary_action["label"],
            "consequence": refinement.get("primary_consequence"),
            "consequence_status": "AUTHORED" if refinement.get("primary_consequence") else "OPEN_IMPLEMENTATION",
            "sources": [
                f"screen-catalog.actions.{primary_action['id']}.label",
                f"screen-catalog.sections.{section['id']}",
            ],
        }
    return {
        "heading": section["title"],
        "explanation": section["purpose"],
        "sources": [f"screen-catalog.sections.{section['id']}"],
    }


def operation_response_names(operation: dict[str, Any]) -> set[str]:
    return {
        field["name"]
        for field in operation.get("response_field_set", [])
        if isinstance(field, dict) and isinstance(field.get("name"), str)
    } | {
        field["name"]
        for field in operation.get("server_only_response_field_set", [])
        if isinstance(field, dict) and isinstance(field.get("name"), str)
    }


def pascal_identifier(value: str) -> str:
    return "".join(part.capitalize() for part in re.split(r"[^A-Za-z0-9]+", value) if part)


def preferred_component_variant(component: dict[str, Any], surface: str) -> str:
    preferences = {
        "public": ("public", "public-record", "policy", "cards", "full", "default"),
        "response": ("response", "form", "linear", "autosave", "privacy", "default"),
        "internal": ("internal", "workspace", "audit-linked", "full", "dense", "default"),
    }[surface]
    variants = component["variants"]
    return next((variant for variant in preferences if variant in variants), variants[0])


def resolve_section_component(
    screen: dict[str, Any],
    section: dict[str, Any],
    component_by: dict[str, dict[str, Any]],
    surface_overrides: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    key = f"{screen['id']}.{section['id']}"
    surface_override = surface_overrides.get(key)
    priority_override = (
        PRIORITY_SCREEN_REFINEMENTS.get(screen["id"], {})
        .get("component_overrides", {})
        .get(section["id"])
    )
    if surface_override is not None:
        if surface_override.get("authority_component") != section["component"]:
            raise ValueError(f"{key}: surface override authority component drifted")
        if priority_override is not None and any(
            surface_override[field] != priority_override[field]
            for field in ("component", "variant")
        ):
            raise ValueError(f"{key}: component override sources conflict")
    if priority_override is not None and surface_override is None:
        raise ValueError(
            f"{key}: priority component assertion is missing from the canonical section override registry"
        )
    selected = surface_override
    component_id = selected["component"] if selected else section["component"]
    component = component_by.get(component_id)
    if component is None:
        raise ValueError(f"{key}: unknown resolved component {component_id}")
    if screen["surface"] not in component["surfaces"]:
        raise ValueError(f"{key}: resolved component does not support {screen['surface']}")
    variant = (
        selected["variant"]
        if selected
        else preferred_component_variant(component, screen["surface"])
    )
    if variant not in component["variants"]:
        raise ValueError(f"{key}: resolved component variant {variant} is invalid")
    if priority_override is not None and surface_override is not None:
        source = "SURFACE_AND_PRIORITY_OVERRIDE_IDENTICAL"
        reason = surface_override["reason"]
    elif priority_override is not None:
        source = "PRIORITY_SEMANTIC_OVERRIDE"
        reason = "The designated critical screen owns an exact component anatomy for this task."
    elif surface_override is not None:
        source = "SURFACE_COMPATIBILITY_OVERRIDE"
        reason = surface_override["reason"]
    else:
        source = "AUTHORITY_COMPONENT"
        reason = "The authority component supports this screen surface and section purpose."
    return {
        "authority_component": section["component"],
        "component": component_id,
        "variant": variant,
        "resolution_source": source,
        "reason": reason,
    }


def response_field_type(operation: dict[str, Any], field_name: str) -> tuple[Any, bool]:
    rows = operation.get("response_field_set", []) + operation.get(
        "server_only_response_field_set", []
    )
    matches = [row for row in rows if row.get("name") == field_name]
    if len(matches) != 1:
        raise ValueError(
            f"{operation['operation_id']}: response field {field_name} is not uniquely typed"
        )
    return matches[0].get("type"), bool(matches[0].get("required"))


def projection_schema(
    screen_id: str, section_id: str, view_model_field: str
) -> dict[str, Any]:
    name = (
        f"{pascal_identifier(screen_id)}{pascal_identifier(section_id)}"
        f"{pascal_identifier(view_model_field)}ProjectionV1"
    )
    return {
        "name": name,
        "kind": "object",
        "additional_properties": False,
        "required": ["summary", "status", "facts", "as_of", "provenance"],
        "fields": {
            "summary": "string[1..4096]",
            "status": "AVAILABLE|EMPTY|PARTIAL|STALE|RESTRICTED|UNAVAILABLE",
            "facts": f"array<{name}FactV1>[0..256]",
            "as_of": "datetime",
            "provenance": f"{name}ProvenanceV1",
        },
        "fact_item": {
            "name": f"{name}FactV1",
            "kind": "object",
            "additional_properties": False,
            "required": ["label", "value", "source_revision", "uncertainty"],
            "fields": {
                "label": "string[1..160]",
                "value": "string[0..4096]",
                "unit": "string[1..64]|null",
                "source_revision": "string[1..256]",
                "locator": "string[1..2048]|null",
                "uncertainty": "CONFIRMED|ESTIMATED|DISPUTED|UNKNOWN|NOT_APPLICABLE",
                "href": "same-origin-authorized-uri-reference|null",
            },
        },
        "provenance_type": {
            "name": f"{name}ProvenanceV1",
            "kind": "object",
            "additional_properties": False,
            "required": ["operation_id", "projection_version", "source_digest"],
            "fields": {
                "operation_id": "operation-id",
                "projection_version": "int64>=1",
                "source_digest": "sha256",
            },
        },
    }


def schema_properties(
    type_name: str,
    base_resources: dict[str, Any],
    additive_resources: dict[str, Any],
) -> list[str] | None:
    base = base_resources.get("resources", {}).get(type_name)
    if isinstance(base, dict):
        schema = base.get("schema", {})
        properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
        if isinstance(properties, dict):
            return sorted(
                name
                for name in properties
                if not is_server_only_browser_field({"name": name})
            )
    additive = additive_resources.get("schemas", {}).get(type_name)
    if isinstance(additive, dict):
        fields = additive.get("fields", {})
        if isinstance(fields, dict):
            return sorted(
                name
                for name in fields
                if not is_server_only_browser_field(
                    {"name": name, "type": fields[name]}
                )
            )
    return None


def type_shape_allowlist(
    field_path: str,
    field_type: Any,
    base_resources: dict[str, Any],
    additive_resources: dict[str, Any],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    raw = str(field_type)
    array_match = re.fullmatch(r"array:(.+)", raw) or re.fullmatch(
        r"array<([^>]+)>(?:\[[^]]+\])?", raw
    )
    if array_match:
        item_type = array_match.group(1)
        if item_type in {"string", "integer", "number", "boolean", "uuid"}:
            item_fields = ["$value"]
        else:
            item_fields = schema_properties(
                item_type, base_resources, additive_resources
            )
            if item_fields is None:
                item_fields = ["$closed_item_schema_required_before_runtime"]
        return None, {
            "path": f"{field_path}[]",
            "item_type": item_type,
            "allowed_item_fields": item_fields,
            "additional_properties": False,
        }
    if raw in {
        "string",
        "integer",
        "number",
        "boolean",
        "date-time",
        "uuid",
        "uri-reference",
        "sha256",
    } or raw.startswith(("enum:", "integer(", "string[", "int64", "decimal")):
        return None, None
    properties = schema_properties(raw, base_resources, additive_resources)
    if properties is None:
        return {
            "path": field_path,
            "type": raw,
            "allowed_fields": ["$closed_object_schema_required_before_runtime"],
            "additional_properties": False,
        }, None
    return {
        "path": field_path,
        "type": raw,
        "allowed_fields": properties,
        "additional_properties": False,
    }, None


def build_section_contracts(
    screen: dict[str, Any],
    manifest_screen: dict[str, Any],
    semantic_contract: dict[str, Any],
    operation_rows: list[dict[str, Any]],
    component_by: dict[str, dict[str, Any]],
    surface_overrides: dict[str, dict[str, Any]],
    base_resources: dict[str, Any],
    additive_resources: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, Any]]]:
    screen_id = screen["id"]
    operation_by = {row["operation_id"]: row for row in operation_rows}
    manifest_section_by = {
        row["id"]: row for row in manifest_screen["section_order"]
    }
    semantic_bindings_by_section: dict[str, list[dict[str, str]]] = {}
    semantic_roles_by_section: dict[str, list[str]] = {}
    for role, contract in semantic_contract.items():
        section_id = contract["section_id"]
        semantic_bindings_by_section.setdefault(section_id, []).extend(
            copy.deepcopy(contract["operation_bindings"])
        )
        semantic_roles_by_section.setdefault(section_id, []).append(role)
    all_section_keys = {f"{screen_id}.{section['id']}" for section in screen["sections"]}
    semantic_section_keys = {
        f"{screen_id}.{section_id}" for section_id in semantic_bindings_by_section
    }
    missing_keys = all_section_keys - semantic_section_keys
    if missing_keys != (set(SECTION_SUPPLEMENTAL_BINDING_ROWS) & all_section_keys):
        raise ValueError(
            f"{screen_id}: supplemental section binding registry is not exact"
        )
    section_rows: list[dict[str, Any]] = []
    runtime_dependencies: list[str] = []
    projection_definitions: list[dict[str, Any]] = []
    for section in sorted(screen["sections"], key=lambda row: row["order"]):
        section_id = section["id"]
        key = f"{screen_id}.{section_id}"
        bindings = list(semantic_bindings_by_section.get(section_id, []))
        if key in SECTION_SUPPLEMENTAL_BINDING_ROWS:
            (raw_bindings,) = SECTION_SUPPLEMENTAL_BINDING_ROWS[key]
            bindings.extend(parse_binding_list(raw_bindings))
        unique_bindings: dict[tuple[str, str, str], dict[str, str]] = {}
        field_sources: dict[str, tuple[str, str]] = {}
        for binding in bindings:
            operation_id = binding["operation_id"]
            operation = operation_by.get(operation_id)
            if operation is None:
                raise ValueError(f"{key}: operation {operation_id} is not bound to screen")
            source = (operation_id, binding["operation_field_path"])
            existing = field_sources.get(binding["view_model_field"])
            if existing is not None and existing != source:
                raise ValueError(f"{key}: view-model field has multiple sources")
            field_sources[binding["view_model_field"]] = source
            unique_bindings[
                (
                    operation_id,
                    binding["operation_field_path"],
                    binding["view_model_field"],
                )
            ] = binding
        if not unique_bindings:
            raise ValueError(f"{key}: closed section slice is empty")
        field_contracts: list[dict[str, Any]] = []
        nested_allowlists: list[dict[str, Any]] = []
        array_allowlists: list[dict[str, Any]] = []
        for _, binding in sorted(unique_bindings.items()):
            operation = operation_by[binding["operation_id"]]
            source_path = binding["operation_field_path"]
            root = source_path.split(".", 1)[0]
            if root == "$projection":
                schema = projection_schema(
                    screen_id, section_id, binding["view_model_field"]
                )
                projection_definitions.append(schema)
                field_type: Any = schema["name"]
                required = True
                source_status = "RUNTIME_PROJECTION_REQUIRED"
                nested_allowlists.append(
                    {
                        "path": binding["view_model_field"],
                        "type": schema["name"],
                        "allowed_fields": list(schema["fields"]),
                        "additional_properties": False,
                    }
                )
                array_allowlists.append(
                    {
                        "path": f"{binding['view_model_field']}.facts[]",
                        "item_type": schema["fact_item"]["name"],
                        "allowed_item_fields": list(schema["fact_item"]["fields"]),
                        "additional_properties": False,
                    }
                )
                runtime_dependencies.append(
                    f"{key}: {binding['operation_id']}.{source_path} must be implemented as {schema['name']}."
                )
            else:
                field_type, required = response_field_type(operation, root)
                source_status = "CURRENT_CLOSED_OPERATION_FIELD"
                nested, array = type_shape_allowlist(
                    binding["view_model_field"],
                    field_type,
                    base_resources,
                    additive_resources,
                )
                if nested is not None:
                    nested_allowlists.append(nested)
                if array is not None:
                    array_allowlists.append(array)
            if is_server_only_browser_field(
                {"name": root, "type": field_type}
            ):
                raise ValueError(f"{key}: server-only source entered section slice")
            field_contracts.append(
                {
                    "name": binding["view_model_field"],
                    "type": field_type,
                    "required": required,
                    "nullable": not required,
                    "source": {
                        "operation_id": binding["operation_id"],
                        "field_path": source_path,
                        "status": source_status,
                    },
                }
            )
        component = resolve_section_component(
            screen, section, component_by, surface_overrides
        )
        slice_name = (
            f"{pascal_identifier(screen_id)}{pascal_identifier(section_id)}SectionVmV1"
        )
        section_rows.append(
            {
                "section_id": section_id,
                "order": section["order"],
                "title": section["title"],
                "purpose": section["purpose"],
                "priority": section["priority"],
                "test_id": manifest_section_by[section_id]["test_id"],
                "semantic_roles": sorted(semantic_roles_by_section.get(section_id, [])),
                "component": component,
                "typed_slice": {
                    "name": slice_name,
                    "kind": "object",
                    "additional_properties": False,
                    "required": sorted(
                        field["name"] for field in field_contracts if field["required"]
                    ),
                    "fields": sorted(field_contracts, key=lambda field: field["name"]),
                },
                "browser_projection_allowlist": {
                    "top_level_fields": sorted(field["name"] for field in field_contracts),
                    "nested_object_fields": sorted(
                        nested_allowlists, key=lambda row: row["path"]
                    ),
                    "array_item_fields": sorted(
                        array_allowlists, key=lambda row: row["path"]
                    ),
                    "deny_unlisted_at_every_depth": True,
                    "unknown_field_behavior": "FAIL_CLOSED_BEFORE_SSR",
                },
            }
        )
    if len(section_rows) != len(screen["sections"]):
        raise ValueError(f"{screen_id}: section registry count changed")
    return section_rows, runtime_dependencies, projection_definitions


def build_authored_semantic_dimensions(
    screen: dict[str, Any],
    manifest_screen: dict[str, Any],
    operation_rows: list[dict[str, Any]],
    primary_action: dict[str, Any],
    refinement: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    screen_id = screen["id"]
    sections = {section["id"]: section for section in screen["sections"]}
    roles = dict(zip(SEMANTIC_DIMENSIONS, SCREEN_SECTION_ROLES[screen_id], strict=True))
    raw_bindings = SCREEN_SEMANTIC_BINDING_ROWS[screen_id]
    operation_by = {row["operation_id"]: row for row in operation_rows}
    semantic_contract: dict[str, Any] = {}
    projection_dependencies: list[str] = []
    for dimension, raw in zip(SEMANTIC_DIMENSIONS, raw_bindings, strict=True):
        section_id = roles[dimension]
        section = sections[section_id]
        bindings = parse_binding_list(raw)
        if not bindings:
            raise ValueError(f"{screen_id}.{dimension}: authored binding list is empty")
        view_model_fields: list[str] = []
        for binding in bindings:
            operation = operation_by.get(binding["operation_id"])
            if operation is None:
                raise ValueError(
                    f"{screen_id}.{dimension}: {binding['operation_id']} is not bound to this screen"
                )
            field_path = binding["operation_field_path"]
            root = field_path.split(".", 1)[0]
            if root == "$projection":
                projection_dependencies.append(
                    f"{screen_id}.{dimension}: {binding['operation_id']}.{field_path} must be added to the closed BFF projection."
                )
            elif root not in operation_response_names(operation):
                raise ValueError(
                    f"{screen_id}.{dimension}: {binding['operation_id']}.{root} is not a response field"
                )
            if is_server_only_browser_field({"name": root}):
                raise ValueError(f"{screen_id}.{dimension}: server-only field entered browser semantics")
            view_model_fields.append(binding["view_model_field"])
        if len(view_model_fields) != len(set(view_model_fields)):
            raise ValueError(f"{screen_id}.{dimension}: duplicate view-model field")
        semantic_contract[dimension] = {
            "section_id": section_id,
            "test_id": next(
                row["test_id"]
                for row in manifest_screen["section_order"]
                if row["id"] == section_id
            ),
            "component": next(
                row["component"]
                for row in manifest_screen["section_order"]
                if row["id"] == section_id
            ),
            "view_model_path": f"sections.{section_id}.{dimension}",
            "required_view_model_fields": view_model_fields,
            "operation_bindings": bindings,
            "copy": semantic_copy_contract(
                screen, section, dimension, primary_action, refinement
            ),
            "binding_status": "OPEN_IMPLEMENTATION"
            if any(row["operation_field_path"].startswith("$projection.") for row in bindings)
            else "CURRENT_OPERATION_FIELDS_BOUND",
        }
    return semantic_contract, projection_dependencies


def build_effective_contracts(
    catalog: dict[str, Any],
    manifest: dict[str, Any],
    archetypes: dict[str, Any],
    data: dict[str, Any],
    addendum_operations: dict[str, Any],
    resources: dict[str, Any],
    base_resources: dict[str, Any],
    component_catalog: dict[str, Any],
    section_surface_overrides: dict[str, Any],
) -> dict[str, Any]:
    catalog_by = unique_by_key(catalog["screens"], "id", "screen catalog")
    screens = [catalog_by[key] for key in sorted(catalog_by)]
    screen_ids = set(catalog_by)
    if set(SCREEN_SECTION_ROLES) != screen_ids:
        raise ValueError("explicit screen section role table is not set-equal to the screen catalog")
    if set(SCREEN_SEMANTIC_BINDING_ROWS) != screen_ids:
        raise ValueError("authored semantic binding registry is not set-equal to the screen catalog")
    manifest_by = unique_by_key(manifest["screens"], "id", "screen build manifest")
    if set(manifest_by) != screen_ids:
        raise ValueError("screen build manifest is not set-equal to screen catalog")
    archetype_by = unique_by_key(archetypes["archetypes"], "id", "page archetypes")
    external_catalog = build_external_operation_catalog(
        data, addendum_operations, resources
    )
    additive_by = {
        operation_id: operation["operation"]
        for operation_id, operation in external_catalog.items()
        if operation["scope"] == "ADDITIVE_EXTERNAL"
    }
    component_by = unique_by_key(
        component_catalog["components"], "id", "component catalog"
    )
    surface_overrides = section_surface_overrides["overrides"]
    semantic_overrides = section_surface_overrides.get("semantic_overrides", {})
    if set(surface_overrides) & set(semantic_overrides):
        raise ValueError("surface and semantic component override registries overlap")
    component_overrides = {**surface_overrides, **semantic_overrides}
    all_section_keys = {
        f"{screen['id']}.{section['id']}"
        for screen in screens
        for section in screen["sections"]
    }
    semantic_section_keys = {
        f"{screen_id}.{section_id}"
        for screen_id, role_values in SCREEN_SECTION_ROLES.items()
        for section_id in role_values
    }
    expected_supplemental_keys = all_section_keys - semantic_section_keys
    if set(SECTION_SUPPLEMENTAL_BINDING_ROWS) != expected_supplemental_keys:
        missing = sorted(expected_supplemental_keys - set(SECTION_SUPPLEMENTAL_BINDING_ROWS))
        extra = sorted(set(SECTION_SUPPLEMENTAL_BINDING_ROWS) - expected_supplemental_keys)
        raise ValueError(
            f"supplemental section binding registry mismatch: missing={missing}, extra={extra}"
        )
    surface_mismatches = {
        f"{screen['id']}.{section['id']}"
        for screen in screens
        for section in screen["sections"]
        if screen["surface"] not in component_by[section["component"]]["surfaces"]
    }
    if set(surface_overrides) != surface_mismatches:
        raise ValueError("surface component override registry is not exact")
    additive_bindings_by_screen: dict[str, list[tuple[str, str]]] = {}
    for operation_id, refs in addendum_operations["operation_screen_bindings"].items():
        if operation_id not in additive_by:
            raise ValueError(f"unknown additive operation screen binding: {operation_id}")
        for ref in refs:
            screen_id, section_id = ref.split(".", 1)
            if screen_id not in catalog_by or section_id not in {
                section["id"] for section in catalog_by[screen_id]["sections"]
            }:
                raise ValueError(f"invalid additive operation section binding: {ref}")
            additive_bindings_by_screen.setdefault(screen_id, []).append((operation_id, section_id))

    rows: list[dict[str, Any]] = []
    for screen in screens:
        screen_id = screen["id"]
        sections = {section["id"]: section for section in screen["sections"]}
        roles = dict(zip(SEMANTIC_DIMENSIONS, SCREEN_SECTION_ROLES[screen_id], strict=True))
        if not set(roles.values()) <= set(sections):
            raise ValueError(f"{screen_id}: explicit semantic section does not exist")
        action_by = {action["id"]: action for action in screen.get("actions", [])}
        primary_action_id = screen.get("primary_action_id")
        refinement = PRIORITY_SCREEN_REFINEMENTS.get(screen_id, {})
        primary_action_id = refinement.get("primary_action_id", primary_action_id)
        if primary_action_id not in action_by and primary_action_id != "NONE":
            raise ValueError(f"{screen_id}: primary action {primary_action_id} is not in the authority catalog")
        primary_action = action_by.get(primary_action_id)
        operation_rows: list[dict[str, Any]] = []
        additive_screen_operations = {
            operation_id
            for operation_id, _section_id in additive_bindings_by_screen.get(
                screen_id, []
            )
        }
        for requirement in screen.get("data_requirements", []):
            operation = validate_screen_data_requirement(
                screen_id, requirement, external_catalog
            )
            if operation["scope"] == "BASE":
                operation_rows.append(base_operation_contract(operation["operation"]))
            elif operation["operation_id"] not in additive_screen_operations:
                raise ValueError(
                    f"{screen_id}:{operation['operation_id']}: additive data requirement "
                    "has no authored section binding"
                )
        operation_rows.sort(key=lambda row: row["operation_id"])
        for operation_id, section_id in sorted(additive_bindings_by_screen.get(screen_id, [])):
            row = additive_operation_contract(additive_by[operation_id], resources)
            row["section_binding"] = section_id
            operation_rows.append(row)
        if primary_action is None:
            raise ValueError(f"{screen_id}: every screen requires an authored primary action")
        semantic_contract, projection_dependencies = build_authored_semantic_dimensions(
            screen,
            manifest_by[screen_id],
            operation_rows,
            primary_action,
            refinement,
        )
        section_contracts, section_projection_dependencies, projection_schemas = (
            build_section_contracts(
                screen,
                manifest_by[screen_id],
                semantic_contract,
                operation_rows,
                component_by,
                component_overrides,
                base_resources,
                resources,
            )
        )
        section_contract_by = {
            section["section_id"]: section for section in section_contracts
        }
        for dimension in semantic_contract.values():
            resolved = section_contract_by[dimension["section_id"]]["component"]
            dimension["authority_component"] = dimension["component"]
            dimension["component"] = resolved["component"]
            dimension["component_variant"] = resolved["variant"]
            dimension["component_resolution_source"] = resolved["resolution_source"]
        integration_dependencies = [
            dependency
            for operation in operation_rows
            for dependency in operation_ui_dependencies(operation)
        ] + projection_dependencies + section_projection_dependencies
        typed_view_model = f"{snake_screen(screen_id).title().replace('_', '')}ScreenVmV1"
        row: dict[str, Any] = {
            "screen_id": screen_id,
            "surface": screen["surface"],
            "route": screen["route"],
            "title": screen["title"],
            "typed_view_model": typed_view_model,
            "view_model_schema": {
                "name": typed_view_model,
                "kind": "object",
                "additional_properties": False,
                "required": [
                    "screen_id",
                    "route",
                    "title",
                    "primary_state",
                    "sections",
                    "primary_action",
                ],
                "fields": {
                    "screen_id": f"literal:{screen_id}",
                    "route": f"literal:{screen['route']}",
                    "title": "string[1..160]",
                    "primary_state": f"{typed_view_model.removesuffix('V1')}PrimaryStateV1",
                    "sections": {
                        "kind": "object",
                        "additional_properties": False,
                        "required": [section["section_id"] for section in section_contracts],
                        "fields": {
                            section["section_id"]: section["typed_slice"]["name"]
                            for section in section_contracts
                        },
                    },
                    "primary_action": f"{typed_view_model.removesuffix('V1')}PrimaryActionV1",
                },
            },
            "semantic_contract": semantic_contract,
            "sections": section_contracts,
            "projection_schema_definitions": sorted(
                projection_schemas, key=lambda schema: schema["name"]
            ),
            "state_profile": screen["state_profile"],
            "state_profile_resolution": canonical_profile_resolution(
                screen,
                manifest_by[screen_id],
                archetype_by[screen["archetype"]],
                archetypes["state_profiles"],
            ),
            "special_state_set": list(screen.get("special_states", [])),
            "primary_action": {
                "action_id": primary_action_id,
                "label": primary_action["label"],
                "consequence": semantic_contract["next_action"]["copy"].get("consequence"),
                "consequence_status": semantic_contract["next_action"]["copy"]["consequence_status"],
                "server_ack_required": not primary_action.get("local_only", False),
            },
            "operation_field_contracts": operation_rows,
            "integration_dependencies": integration_dependencies,
            "design_contract_status": "DECISION_FINAL",
            "runtime_implementation_status": "OPEN_IMPLEMENTATION",
            "dto_rendering_forbidden": True,
            "raw_json_form_forbidden": True,
        }
        if refinement:
            row["priority_semantic_refinement"] = copy.deepcopy(refinement)
        rows.append(row)
    manifest_mismatches = sum(
        set(manifest_by[screen["id"]]["states"])
        != set(archetypes["state_profiles"][screen["state_profile"]])
        for screen in screens
    )
    archetype_mismatches = sum(
        archetype_by[screen["archetype"]]["default_state_profile"]
        != screen["state_profile"]
        for screen in screens
    )
    expected_profile_occurrences = sum(
        len(archetypes["state_profiles"][screen["state_profile"]]) for screen in screens
    )
    return {
        "schema_version": 1,
        "specification_version": "13.0.0+owner-ui-closure.2",
        "status": "DECISION_FINAL",
        "runtime_implementation_status": "OPEN_IMPLEMENTATION",
        "authority_mode": "ADDITIVE_OVERLAY",
        "sources": [
            "specs/ui/screen-catalog.yaml",
            "specs/ui/screen-build-manifest.yaml",
            "specs/ui/page-archetypes.yaml",
            "specs/ui/screen-data-contracts.yaml",
            "specs/ui/component-catalog.yaml",
            "specs/product/addendum-operation-contracts.yaml",
            "specs/product/addendum-resource-error-contracts.yaml",
        ],
        "rules": [
            "The screen set is exactly equal to the 94-screen authority catalog.",
            "Every screen binds object, state, answer, evidence, unknown and next action through its authored operation-to-field registry.",
            "A route renders only its screen-specific typed view-model; generic renderers, response dumps and JSON forms are forbidden.",
            "Operation field sets are copied from their exact closed contracts and do not authorize presentation of every DTO field.",
            "User copy is copied verbatim from screen-specific catalog text or an explicit priority refinement; no sentence generator is permitted.",
            "A $projection binding is an OPEN_IMPLEMENTATION requirement, never evidence that the field exists.",
        ],
        "counts": {
            "screens": len(rows),
            "sections": sum(len(row["sections"]) for row in rows),
            "closed_screen_view_model_types": len(
                {row["typed_view_model"] for row in rows}
            ),
            "closed_section_view_model_types": len(
                {
                    section["typed_slice"]["name"]
                    for row in rows
                    for section in row["sections"]
                }
            ),
            "explicit_browser_projection_allowlists": sum(
                len(row["sections"]) for row in rows
            ),
            "semantic_dimensions_per_screen": 6,
            "base_operation_occurrences": sum(
                sum(
                    external_catalog[requirement["operation_id"]]["scope"] == "BASE"
                    for requirement in screen.get("data_requirements", [])
                )
                for screen in screens
            ),
            "additive_operation_section_occurrences": sum(
                len(value) for value in addendum_operations["operation_screen_bindings"].values()
            ),
            "screens_requiring_api_or_bff_projection_work": sum(
                bool(row["integration_dependencies"]) for row in rows
            ),
            "build_manifest_profile_refinements": manifest_mismatches,
            "archetype_default_overrides": archetype_mismatches,
        },
        "canonical_profile_set_equality_oracle": {
            "screen_key_set": "effective screens == screen-catalog screens == screen-build-manifest screens",
            "row_count": 94,
            "canonical_profile_source_count": 94,
            "manifest_refinement_count": manifest_mismatches,
            "archetype_override_count": archetype_mismatches,
            "canonical_profile_state_occurrences": sum(
                len(row["state_profile_resolution"]["canonical_states"])
                for row in rows
            ),
            "expected_profile_state_occurrences": expected_profile_occurrences,
            "failure_rule": "Missing, extra, unmapped, multiply canonical, or source-order-derived profile rows fail validation.",
        },
        "screen_section_set_equality_oracle": {
            "screen_ids": len(screen_ids),
            "catalog_section_keys": len(all_section_keys),
            "effective_section_keys": sum(len(row["sections"]) for row in rows),
            "semantic_anchor_section_keys": len(semantic_section_keys),
            "supplemental_section_keys": len(SECTION_SUPPLEMENTAL_BINDING_ROWS),
            "missing": 0,
            "extra": 0,
            "duplicate": 0,
            "rule": "effective section keys == catalog section keys == semantic-anchor union supplemental authored keys",
        },
        "browser_secret_stripping_contract": {
            "server_only_field_names": sorted(SERVER_ONLY_BROWSER_FIELD_NAMES),
            "required_exchange_sequence": [
                "consume one-time token only in the server endpoint",
                "issue a scope-limited HttpOnly Secure SameSite cookie",
                "redirect with 303 to the canonical token-free route",
                "render only safe receipt identity and status fields",
            ],
            "forbidden_browser_sinks": [
                "route",
                "query",
                "fragment",
                "SSR HTML",
                "hydration payload",
                "DOM",
                "accessibility tree",
                "analytics",
                "referrer",
                "history state",
                "client storage",
                "console",
                "client log",
            ],
            "set_equality_scan": "all 94 closed screen schemas + all 492 section leaf/nested/array allowlists + all action and journey browser bindings",
            "runtime_status": "OPEN_IMPLEMENTATION",
        },
        "implementation_requirements": [
            "Generate one handwritten BFF mapper and one runtime validator for each typed_view_model; a generic screen mapper is forbidden.",
            "Resolve every per-screen integration_dependencies item in the owning API/resource schema before implementation status can become FINAL.",
            "Add field-removal contract tests proving object, state, answer, evidence, unknown, owner/deadline and next-action fields are required.",
            "Provide realistic non-empty fixtures for all 94 view-models without exposing token, session, credential or assertion fields.",
        ],
        "screens": rows,
    }


def placement_state_contract(
    selected_target_source: str,
    form_source: str,
    session_source: str,
    receipt_source: str,
    handler_id: str,
) -> list[dict[str, Any]]:
    handler_state = f"runtime_handlers.{handler_id}"
    return [
        {
            "state": "loading",
            "trigger": {"path": f"{selected_target_source}.load_state", "op": "eq", "value": "LOADING"},
            "visible": True,
            "enabled": False,
            "safe_action": "WAIT_FOR_SELECTED_TARGET",
        },
        {
            "state": "blocked",
            "trigger": {"path": f"{selected_target_source}.blocking_reasons", "op": "count_gt", "value": 0},
            "visible": True,
            "enabled": False,
            "safe_action": "FOCUS_FIRST_OWNED_BLOCKER",
        },
        {
            "state": "stale",
            "trigger": {"path": f"{selected_target_source}.digest_current", "op": "eq", "value": False},
            "visible": True,
            "enabled": False,
            "safe_action": "REFRESH_AND_COMPARE_SELECTED_TARGET",
        },
        {
            "state": "conflict",
            "trigger": {"path": f"{form_source}.server_conflict_diff", "op": "present"},
            "visible": True,
            "enabled": False,
            "safe_action": "PRESERVE_FORM_AND_SHOW_READABLE_DIFF",
        },
        {
            "state": "reauth-required",
            "trigger": {"path": f"{session_source}.action_authorization_state", "op": "eq", "value": "REQUIRED"},
            "visible": True,
            "enabled": False,
            "safe_action": "AUTHORIZE_EXACT_HANDLER_DIGEST",
        },
        {
            "state": "submitting",
            "trigger": {"path": f"{handler_state}.phase", "op": "in", "value": ["CLAIMED", "DISPATCHING"]},
            "visible": True,
            "enabled": False,
            "safe_action": "KEEP_IDEMPOTENCY_KEY_AND_WAIT",
        },
        {
            "state": "receipt",
            "trigger": {"path": receipt_source, "op": "validated"},
            "visible": True,
            "enabled": False,
            "safe_action": "FOCUS_OWNED_RECEIPT_DESTINATION",
        },
        {
            "state": "partial-failure",
            "trigger": {"path": f"{handler_state}.effect_certainty", "op": "eq", "value": "MAY_EXIST"},
            "visible": True,
            "enabled": False,
            "safe_action": "RECONCILE_BEFORE_ANY_RETRY",
        },
        {
            "state": "terminal",
            "trigger": {"path": f"{handler_state}.phase", "op": "in", "value": ["CANCELLED", "REJECTED", "EXPIRED"]},
            "visible": False,
            "enabled": False,
            "safe_action": "SHOW_TERMINAL_REASON_AND_RECEIPT",
        },
    ]


IMMUTABLE_REQUEST_FIELD_NAMES = {
    "actionDigest",
    "authorizationReceiptId",
    "declarationId",
    "deliveryId",
    "expectedActionDigest",
    "expectedDeclarationDigest",
    "expectedDeclarationSequence",
    "expectedPolicyDigest",
    "expectedPriorSequence",
    "expectedProposalDigest",
    "expectedProposalVersion",
    "expectedReceiptVersion",
    "expectedVersion",
    "executionId",
    "incidentId",
    "policyDigest",
    "proposalId",
    "receiptId",
    "requestId",
    "reviewAssignmentId",
    "subjectActorId",
}


def step_up_contract(assurance: str) -> dict[str, Any]:
    if assurance == "STEP_UP":
        mode = "REQUIRED"
    elif assurance.startswith("conditional"):
        mode = "CONDITIONAL"
    elif assurance == "RECENT_SESSION":
        mode = "RECENT_SESSION_REQUIRED"
    else:
        mode = "NOT_REQUIRED"
    return {
        "mode": mode,
        "assurance": assurance,
        "binding": "exact proposal/action/decision digest + expected versions + bounded authorization receipt",
        "rule": "Confirmation UI never substitutes for a required or conditional step-up authorization.",
    }


def exact_request_bindings(
    screen_id: str,
    operation: dict[str, Any],
    action_id: str,
    selected_target_source: str,
    form_source: str,
) -> list[dict[str, Any]]:
    request = operation.get("request", {})
    required = set(request.get("required", []))
    path_parameters = set(re.findall(r"\{([^}]+)\}", operation["path"]))
    return [
        {
            "field": name,
            "type": field_type,
            "required": name in required,
            "source": f"request_context.server_only_exchange_input.{name}"
            if is_server_only_browser_field({"name": name, "type": field_type})
            else f"{selected_target_source}.{name}"
            if name in path_parameters
            or name in IMMUTABLE_REQUEST_FIELD_NAMES
            or name.startswith("expected")
            else f"{form_source}.{name}",
            "binding_class": "SERVER_ONLY_CONSUMED_BEFORE_RENDER"
            if is_server_only_browser_field({"name": name, "type": field_type})
            else "IMMUTABLE_SELECTED_TARGET"
            if name in path_parameters
            or name in IMMUTABLE_REQUEST_FIELD_NAMES
            or name.startswith("expected")
            else "USER_EDITABLE_FORM_FIELD",
            "browser_visible": not is_server_only_browser_field({"name": name, "type": field_type}),
            "error_test_id": None
            if is_server_only_browser_field({"name": name, "type": field_type})
            else f"{snake_screen(screen_id)}__field_error__{action_id.replace('-', '_')}__{name}",
        }
        for name, field_type in request.get("fields", {}).items()
    ]


def build_action_contracts(
    catalog: dict[str, Any],
    manifest: dict[str, Any],
    addendum_operations: dict[str, Any],
    resources: dict[str, Any],
) -> dict[str, Any]:
    command_by = {
        operation["operation_id"]: operation
        for operation in addendum_operations["operations"]
        if operation["kind"] == "COMMAND"
    }
    if set(command_by) != set(COMMAND_PRESENTATION):
        raise ValueError("command presentation table is not set-equal to additive command operations")
    screen_by = {screen["id"]: screen for screen in catalog["screens"]}
    manifest_by = {screen["id"]: screen for screen in manifest["screens"]}
    expected_placement_keys = {
        f"{operation_id}@{reference}"
        for operation_id, references in addendum_operations["operation_screen_bindings"].items()
        if operation_id in command_by
        for reference in references
    }
    if set(COMMAND_PLACEMENT_ROWS) != expected_placement_keys:
        missing = sorted(expected_placement_keys - set(COMMAND_PLACEMENT_ROWS))
        extra = sorted(set(COMMAND_PLACEMENT_ROWS) - expected_placement_keys)
        raise ValueError(f"authored command placement mismatch: missing={missing}, extra={extra}")
    commands: list[dict[str, Any]] = []
    placement_count = 0
    additive_action_entries: list[dict[str, Any]] = []
    for operation_id in sorted(command_by):
        operation = command_by[operation_id]
        label, consequence = COMMAND_PRESENTATION[operation_id]
        refs = addendum_operations["operation_screen_bindings"][operation_id]
        placements: list[dict[str, Any]] = []
        for ref in refs:
            screen_id, section_id = ref.split(".", 1)
            screen = screen_by[screen_id]
            section_test_id = next(
                row["test_id"]
                for row in manifest_by[screen_id]["section_order"]
                if row["id"] == section_id
            )
            placement_key = f"{operation_id}@{ref}"
            (
                action_id,
                selected_target_source,
                form_source,
                session_source,
                receipt_source,
                target_screen,
                target_section,
                handler_id,
            ) = COMMAND_PLACEMENT_ROWS[placement_key]
            target_section_test_id = next(
                row["test_id"]
                for row in manifest_by[target_screen]["section_order"]
                if row["id"] == target_section
            )
            provider_proposal_destination = (
                placement_key == "createActionProposal@OPS-005.status"
            )
            target_route = (
                "/internal/my-work?proposalId={proposalId}"
                if provider_proposal_destination
                else screen_by[target_screen]["route"]
            )
            destination_parameters = re.findall(r"\{([^}]+)\}", target_route)
            success_focus_test_id = (
                f"{snake_screen(target_screen)}__receipt__{handler_id}__heading"
            )
            placement = {
                "placement_key": placement_key,
                "screen_id": screen_id,
                "section_id": section_id,
                "section_test_id": section_test_id,
                "action_id": action_id,
                "action_test_id": f"{snake_screen(screen_id)}__action__{action_id.replace('-', '_')}",
                "selected_target_source": selected_target_source,
                "form_source": form_source,
                "session_authority_source": session_source,
                "request_bindings": exact_request_bindings(
                    screen_id,
                    operation,
                    action_id,
                    selected_target_source,
                    form_source,
                ),
                "idempotency_binding": f"request_context.idempotency_keys.{handler_id}",
                "enabled_when": {
                    "all": [
                        {"path": f"{selected_target_source}.load_state", "op": "eq", "value": "READY"},
                        {"path": f"{selected_target_source}.digest_current", "op": "eq", "value": True},
                        {"path": f"{selected_target_source}.blocking_reasons", "op": "count_eq", "value": 0},
                        {"path": f"runtime_handlers.{handler_id}.phase", "op": "eq", "value": "IDLE"},
                    ]
                },
                "placement_state_contract": placement_state_contract(
                    selected_target_source,
                    form_source,
                    session_source,
                    receipt_source,
                    handler_id,
                ),
                "receipt_source": receipt_source,
                "handler_id": handler_id,
                "success_destination": {
                    "screen_id": target_screen,
                    "section_id": target_section,
                    "route": target_route,
                    "required_route_bindings": {
                        parameter: f"{receipt_source}.{parameter}"
                        if provider_proposal_destination
                        else f"{receipt_source}.destination_bindings.{parameter}"
                        for parameter in destination_parameters
                    },
                    "section_heading_test_id": target_section_test_id,
                    "receipt_focus_test_id": success_focus_test_id,
                    "receipt_anchor": f"action-receipt-{handler_id}",
                    "history": "REPLACE_STATE_AFTER_RECEIPT"
                    if target_screen == screen_id
                    else "PUSH_AFTER_RECEIPT",
                },
                "failure_focus_test_id": f"{snake_screen(screen_id)}__command_error__{action_id.replace('-', '_')}",
                "implementation_status": "OPEN_IMPLEMENTATION",
            }
            placements.append(placement)
            additive_action_entries.append(
                {
                    "action_key": f"{screen_id}.{action_id}",
                    "operation_id": operation_id,
                    "placement_key": placement_key,
                    "section_id": section_id,
                    "handler_id": handler_id,
                }
            )
        placement_count += len(placements)
        request = operation.get("request", {})
        required = set(request.get("required", []))
        command_contract = {
                "operation_id": operation_id,
                "label": label,
                "consequence": consequence,
                "api": operation["api"],
                "method": operation["method"],
                "path": operation["path"],
                "authorization": operation.get("authorization", operation.get("capability")),
                "step_up": step_up_contract(operation["assurance"]),
                "request_field_set": [
                    {"name": name, "type": field_type, "required": name in required}
                    for name, field_type in request.get("fields", {}).items()
                ],
                "receipt_schema": operation["response"],
                "receipt_field_set": schema_fields(operation["response"], resources),
                "concurrency": operation.get("concurrency"),
                "transition": operation.get("transition"),
                "placements": placements,
            }
        command_contract.update(
            COMMAND_RECEIPT_PRESENTATION_OVERRIDES.get(operation_id, {})
        )
        commands.append(command_contract)
    additive_action_keys = [row["action_key"] for row in additive_action_entries]
    if len(additive_action_keys) != len(set(additive_action_keys)):
        raise ValueError("command-qualified additive action IDs are not unique")
    base_action_keys = {
        f"{screen['id']}.{action['id']}"
        for screen in catalog["screens"]
        for action in screen.get("actions", [])
    }
    if base_action_keys & set(additive_action_keys):
        raise ValueError("additive command action collides with a base screen action")
    request_bindings = [
        binding
        for command in commands
        for placement in command["placements"]
        for binding in placement["request_bindings"]
    ]
    browser_visible_secret_bindings = [
        binding
        for binding in request_bindings
        if binding["browser_visible"]
        and is_server_only_browser_field(binding)
    ]
    if browser_visible_secret_bindings:
        raise ValueError("server-only token/proof entered a browser-visible command binding")
    proposal_screens = {
        reference.split(".", 1)[0]
        for reference in addendum_operations["operation_screen_bindings"]["createActionProposal"]
    }
    provider_control_operation_ids = {
        "disableProviderRouting",
        "testProviderConnection",
        "upgradeProviderModel",
        "setModelAutoUpgrade",
    }
    legacy_side_door_fences: list[dict[str, Any]] = []
    for screen_id in sorted(proposal_screens):
        screen = screen_by[screen_id]
        for action in screen.get("actions", []):
            if not action.get("operation_id"):
                continue
            fence = {
                "screen_id": screen_id,
                "legacy_action_id": action["id"],
                "legacy_operation_id": action["operation_id"],
                "policy": "PROPOSAL_ONLY_UNTIL_AUTHORIZED_EXECUTION",
                "required_entry_operation": "createActionProposal",
                "direct_effect_forbidden": True,
                "completion_requires": "ActionExecutionReceiptV1 with the same proposal/action digest",
            }
            if (
                screen_id == "OPS-005"
                and action["operation_id"] in provider_control_operation_ids
            ):
                fence["proposal_binding"] = {
                    "actionKind": "PROVIDER_CONTROL",
                    "providerControl.operationId": action["operation_id"],
                }
            legacy_side_door_fences.append(fence)
    provider_control_fences = {
        fence["legacy_operation_id"]
        for fence in legacy_side_door_fences
        if fence["screen_id"] == "OPS-005"
        and fence.get("proposal_binding", {}).get("actionKind") == "PROVIDER_CONTROL"
    }
    if provider_control_fences != provider_control_operation_ids:
        raise ValueError("OPS-005 provider-control proposal fences are not closed")

    journey_actions = copy.deepcopy(JOURNEY_VISIBLE_ACTIONS)
    for screen_id, refinement in PRIORITY_SCREEN_REFINEMENTS.items():
        for action in refinement.get("required_additional_actions", []):
            journey_actions.append(
                {
                    "screen_id": screen_id,
                    "section_id": SCREEN_SECTION_ROLES[screen_id][-1],
                    "action_id": action["action_id"],
                    "label": action["label"],
                    "destination_screen_id": action["destination_screen_id"],
                    "bindings": copy.deepcopy(action["required_bindings"]),
                    "focus_test_id": action["focus_test_id"],
                }
            )
    normalized_journey_actions: list[dict[str, Any]] = []
    seen_journey_action_keys: set[str] = set()
    for action in journey_actions:
        key = f"{action['screen_id']}.{action['action_id']}"
        if key in seen_journey_action_keys:
            raise ValueError(f"duplicate additive journey action: {key}")
        seen_journey_action_keys.add(key)
        source_screen = screen_by[action["screen_id"]]
        target_screen = screen_by[action["destination_screen_id"]]
        if action["section_id"] not in {section["id"] for section in source_screen["sections"]}:
            raise ValueError(f"{key}: journey action section is not authoritative")
        normalized_journey_actions.append(
            {
                **action,
                "action_key": key,
                "action_test_id": f"{snake_screen(action['screen_id'])}__action__{action['action_id'].replace('-', '_')}",
                "destination_route": target_screen["route"],
                "focus_test_id": action.get(
                    "focus_test_id", f"{snake_screen(action['destination_screen_id'])}__heading"
                ),
                "history": "PUSH",
                "safe_return": {
                    "screen_id": action["screen_id"],
                    "route": source_screen["route"],
                },
                "invalid_binding_behavior": "disable this exact action, focus its inline error, and never guess an identity",
            }
        )
    journey_action_keys = {row["action_key"] for row in normalized_journey_actions}
    if base_action_keys & journey_action_keys or set(additive_action_keys) & journey_action_keys:
        raise ValueError("journey action collides with a base or command-qualified action")
    return {
        "schema_version": 1,
        "specification_version": "13.0.0+owner-ui-actions.2",
        "status": "OPEN_IMPLEMENTATION",
        "authority_mode": "ADDITIVE_OVERLAY",
        "sources": [
            "specs/product/addendum-operation-contracts.yaml",
            "specs/product/addendum-resource-error-contracts.yaml",
            "specs/ui/screen-catalog.yaml",
            "specs/ui/screen-build-manifest.yaml",
        ],
        "rules": [
            "The command set is exactly equal to the current additive external command source set.",
            "Every command has at least one visible section placement, explicit state availability, consequence, assurance, receipt and focus destination.",
            "A command is never enabled by primary state alone and never reports success before its closed receipt validates.",
            "The exact proposal content, recipient, reason, effect, risk and cost precede any human approval.",
            "Every placement owns a command-qualified action ID, selected target, form, session authority, handler, receipt and route destination.",
        ],
        "counts": {
            "commands": len(commands),
            "visible_placements": placement_count,
            "journey_visible_actions": len(normalized_journey_actions),
            "legacy_side_door_fences": len(legacy_side_door_fences),
            "base_actions": len(base_action_keys),
            "effective_actions": (
                len(base_action_keys)
                + len(additive_action_entries)
                + len(normalized_journey_actions)
            ),
        },
        "action_registry_set_equality": {
            "base_source": "specs/ui/screen-catalog.yaml#screens[].actions[]",
            "base_keys": len(base_action_keys),
            "additive_source": "command placement registry",
            "additive_keys": len(additive_action_entries),
            "journey_source": "explicit canonical journey visible-action registry",
            "journey_keys": len(normalized_journey_actions),
            "overlap": 0,
            "effective_rule": "effective actions = disjoint union(base actions, additive command actions, journey visible actions)",
            "runtime_status": "OPEN_IMPLEMENTATION",
        },
        "browser_secret_binding_oracle": {
            "request_bindings": len(request_bindings),
            "server_only_consumed_before_render": sum(
                binding["binding_class"] == "SERVER_ONLY_CONSUMED_BEFORE_RENDER"
                for binding in request_bindings
            ),
            "browser_visible_secret_bindings": 0,
            "failure_rule": "Any raw token, proof, credential, assertion or session value in a view-model/form/action/DOM binding fails generation.",
        },
        "commands": commands,
        "additive_action_entries": additive_action_entries,
        "priority_screen_refinements": copy.deepcopy(PRIORITY_SCREEN_REFINEMENTS),
        "journey_visible_actions": normalized_journey_actions,
        "legacy_side_door_fences": legacy_side_door_fences,
        "implementation_requirements": [
            "Render every additive_action_entry as a labelled control in its exact section and bind every request field to the authored selected-target or form path.",
            "Generate command-state tests for loading, blocked, stale, conflict, reauth, submitting, receipt, partial-failure and terminal behavior.",
            "Remove direct-effect handlers fenced by legacy_side_door_fences; they may only create proposals until an authorization receipt exists.",
            "After a validated receipt, move focus to success_destination; on failure, preserve input and focus failure_focus_test_id.",
        ],
    }


PRESERVE_COPY = {
    "search-input-and-filters": "입력한 검색어와 유효한 필터를 유지한다.",
    "none": "보존할 사용자 입력이 없다.",
    "truthful-saved-state-and-support-reference": "실제 저장 여부와 지원 참조번호를 보존한다.",
    "request-reference-without-object-detail": "보호 대상의 존재는 숨기고 요청 참조만 보존한다.",
    "visible-data-and-focus": "표시된 데이터와 현재 초점을 유지한다.",
    "scope-and-freshness": "조회 범위와 기준 시각을 유지한다.",
    "available-data-freshness-and-missing-scope": "확인 가능한 데이터·기준 시각·누락 범위를 유지한다.",
    "last-verified-data-and-as-of": "마지막 검증 데이터와 기준 시각을 유지한다.",
    "visible-data-local-input-and-last-server-ack": "표시 데이터·로컬 입력·마지막 서버 저장 확인을 유지한다.",
    "safe-return-and-truthful-draft-state": "안전한 돌아가기 경로와 실제 초안 저장 상태를 유지한다.",
    "attempted-input-server-version-and-readable-diff": "시도 입력·서버 버전·읽을 수 있는 차이를 유지한다.",
    "affected-scope-last-good-time-and-workaround": "영향 범위·마지막 정상 시각·안전한 대체 경로를 유지한다.",
    "query-filters-sort": "검색어·필터·정렬을 유지한다.",
    "current-authoritative-data-or-receipt": "현재 권위 데이터 또는 영수증을 유지한다.",
    "server-ack-version-and-current-input": "서버 확인 버전과 현재 입력을 유지한다.",
    "input-focus-and-idempotency-key": "입력·초점·중복 방지 키를 유지한다.",
    "server-ack-version-and-saved-at": "서버 확인 버전과 저장 시각을 유지한다.",
    "target-digest-draft-and-blocker-evidence": "대상 무결성 값·초안·차단 근거를 유지한다.",
    "entered-query-and-valid-filters": "입력 검색어와 유효한 필터를 유지한다.",
    "content-version-effective-date-owner": "내용 버전·적용일·책임자를 유지한다.",
    "historical-version-and-effective-period": "과거 버전과 적용 기간을 유지한다.",
    "all-entered-values": "모든 입력값을 유지한다.",
    "draft-and-last-server-ack": "초안과 마지막 서버 저장 확인을 유지한다.",
    "draft-server-ack-and-safe-return": "초안·서버 저장 확인·안전한 돌아가기 경로를 유지한다.",
    "target-content-and-decision-digest": "대상 내용과 결정 무결성 값을 유지한다.",
    "target-digest-reason-draft-and-safe-return": "대상 무결성 값·이유 초안·안전한 돌아가기 경로를 유지한다.",
    "decision-digest-input-and-idempotency-key": "결정 무결성 값·입력·중복 방지 키를 유지한다.",
    "receipt-target-digest-actor-time-and-links": "영수증·대상 무결성 값·처리자·시각·후속 링크를 유지한다.",
    "all-known-receipts-and-no-retry-fence": "확인된 영수증과 재시도 금지 경계를 유지한다.",
    "window-build-and-evidence-receipt": "관측 구간·빌드·근거 영수증을 유지한다.",
    "severity-impact-owner-next-update-and-evidence": "심각도·영향·담당자·다음 공지 시각·근거를 유지한다.",
    "last-observation-gap-scope-and-escalation": "마지막 관측·누락 범위·에스컬레이션을 유지한다.",
    "safe-navigation-only": "안전한 이동 경로만 유지한다.",
    "truthful-server-saved-state-and-safe-return": "실제 서버 저장 상태와 안전한 돌아가기 경로를 유지한다.",
    "scope-start-end-status-reference": "범위·시작·종료·상태·참조번호를 유지한다.",
}


ACTION_COPY = {
    "enter-or-choose-query": "검색어를 입력하거나 예시 검색어·기관 대장을 선택한다.",
    "none": "현재 상태가 끝날 때까지 추가 행동을 하지 않는다.",
    "retry-when-safe": "외부 효과와 중복 여부를 확인한 뒤 안전한 경우에만 다시 시도한다.",
    "request-access-or-safe-return": "권한을 요청하거나 안전한 화면으로 돌아간다.",
    "keep-safe-actions": "영향받지 않은 읽기 행동만 이용한다.",
    "screen-empty-recovery": "조회 범위나 조건을 명시적으로 바꾼다.",
    "retry-missing-slice": "누락된 범위만 다시 불러온다.",
    "refresh-read-only": "현재 자료를 읽기 전용으로 유지하며 최신본을 확인한다.",
    "disable-network-actions-until-online": "연결이 복구될 때까지 네트워크 행동을 중지한다.",
    "authenticate": "인증 후 검증된 돌아가기 경로로 복귀한다.",
    "reload-compare-or-reapply-explicitly": "최신본과 차이를 읽고 명시적으로 다시 적용한다.",
    "bounded-recovery": "표시된 영향 범위 안에서 복구 절차를 실행한다.",
    "clear-or-edit-filter": "필터를 지우거나 수정한다.",
    "screen-primary": "현재 화면의 명시된 주 행동을 이용한다.",
    "screen-draft-actions": "초안을 계속 작성하거나 명시적으로 저장한다.",
    "prevent-duplicate-submit": "중복 제출하지 않고 기존 처리 결과를 확인한다.",
    "continue-editing": "오류가 있는 입력으로 이동해 수정한다.",
    "resolve-owned-blocker": "담당자가 표시된 차단 요인을 해결한다.",
    "correct-filter": "유효하지 않은 검색 조건을 수정한다.",
    "policy-navigation": "현재 정책이나 변경 이력을 연다.",
    "open-current-version": "현재 적용 버전으로 이동한다.",
    "correct-linked-fields": "오류 요약에서 연결된 필드로 이동해 수정한다.",
    "retry-same-idempotency-key-when-safe": "안전성이 확인된 경우 같은 중복 방지 키로 다시 시도한다.",
    "renew-or-submit-safely": "세션을 갱신하거나 저장 상태를 확인한 뒤 제출한다.",
    "exact-decision": "고정된 대상에 구조화된 결정을 제출한다.",
    "reauthenticate-for-exact-action": "정확한 행동 무결성 값에 결속된 재인증을 완료한다.",
    "disable-duplicate-submit": "처리 영수증이 확인될 때까지 다시 제출하지 않는다.",
    "receipt-next-actions": "영수증을 보관하고 표시된 다음 절차를 이용한다.",
    "reconcile-not-retry": "외부 효과를 다시 실행하지 말고 결과를 대조한다.",
    "operations-navigation": "영향 범위와 운영 이력을 확인한다.",
    "open-incident": "사고 상세와 대응 runbook을 연다.",
    "investigate-telemetry-gap": "관측 누락 범위와 복구 담당자를 확인한다.",
    "safe-home-or-search": "안전한 홈이나 검색으로 이동한다.",
    "authenticate-or-request-new-access": "인증하거나 새 접근 링크를 요청한다.",
    "status-or-safe-return": "공개 상태를 확인하거나 안전한 화면으로 돌아간다.",
}


PROFILE_PRECEDENCE = {
    "not-found": 980,
    "forbidden": 970,
    "unauthorized": 965,
    "unauthenticated": 965,
    "session-expired": 960,
    "error": 950,
    "server-error": 950,
    "conflict": 920,
    "reauth-required": 910,
    "blocked": 900,
    "partial-failure": 880,
    "validation-error": 820,
    "invalid-filter": 820,
    "offline": 780,
    "incident": 770,
    "degraded": 760,
    "telemetry-gap": 750,
    "maintenance": 740,
    "stale": 700,
    "session-expiring": 680,
    "superseded": 640,
    "receipt": 610,
    "submitting": 560,
    "saving": 550,
    "refreshing": 540,
    "initial-loading": 500,
    "loading": 500,
    "partial": 450,
    "empty": 350,
    "filtered-empty": 340,
    "draft": 300,
    "saved": 280,
    "ready": 260,
    "current": 240,
    "healthy": 230,
    "success": 220,
    "awaiting-query": 200,
}


SPECIAL_SIGNAL_FAMILIES: dict[str, tuple[str, str, str, str]] = {
    "access": ("ACCESS_DECISION", "view_model.access_decision.reason_codes", "contains", "view_model.access_decision.evidence_by_code"),
    "blocked": ("BLOCKER", "view_model.blockers.codes", "contains", "view_model.blockers.evidence_by_code"),
    "conflict": ("CONCURRENCY", "view_model.concurrency.conflict_codes", "contains", "view_model.concurrency.evidence_by_code"),
    "degraded": ("CONNECTIVITY_OR_DEPENDENCY", "view_model.connectivity.degradation_codes", "contains", "view_model.connectivity.evidence_by_code"),
    "empty": ("AUTHORIZED_QUERY", "view_model.query_result.empty_reason_codes", "contains", "view_model.query_result.evidence_by_code"),
    "failure": ("OPERATION_FAILURE", "view_model.operation_status.failure_codes", "contains", "view_model.operation_status.failure_evidence_by_code"),
    "pending": ("OPERATION_PHASE", "view_model.operation_status.pending_codes", "contains", "view_model.operation_status.pending_evidence_by_code"),
    "receipt": ("VALIDATED_RECEIPT", "view_model.receipts.outcome_codes", "contains", "view_model.receipts.receipt_by_code"),
    "security": ("TRUST_SIGNAL", "view_model.trust_signals.codes", "contains", "view_model.trust_signals.evidence_by_code"),
    "stale": ("PROJECTION_FRESHNESS", "view_model.projection.freshness_codes", "contains", "view_model.projection.evidence_by_code"),
    "success": ("OPERATION_OUTCOME", "view_model.operation_status.outcome_codes", "contains", "view_model.operation_status.receipt_by_code"),
    "terminal": ("RESOURCE_LIFECYCLE", "view_model.resource.lifecycle_codes", "contains", "view_model.resource.receipt_by_code"),
    "validation": ("FORM_VALIDATION", "view_model.validation.issue_codes", "contains", "view_model.validation.evidence_by_code"),
}


SPECIAL_SIGNAL_OVERRIDES: dict[str, tuple[str, str, str, Any, str]] = {
    "offline": ("CONNECTIVITY", "view_model.connectivity.online", "eq", False, "view_model.connectivity.last_verified_at"),
    "network-retry": ("CONNECTIVITY", "view_model.connectivity.retry_phase", "eq", "BOUNDED_RETRY", "view_model.connectivity.retry_receipt"),
    "token-expired": ("SCOPED_SESSION", "request_context.scoped_session.link_state", "eq", "EXPIRED", "request_context.scoped_session.exchange_receipt_id"),
    "token-revoked": ("SCOPED_SESSION", "request_context.scoped_session.link_state", "eq", "REVOKED", "request_context.scoped_session.exchange_receipt_id"),
    "receipt-expired-link": ("SCOPED_SESSION", "request_context.scoped_session.link_state", "eq", "EXPIRED", "request_context.scoped_session.exchange_receipt_id"),
    "session-risk": ("SCOPED_SESSION", "request_context.scoped_session.risk_state", "eq", "ELEVATED", "request_context.scoped_session.risk_receipt_id"),
    "submission-receipt": ("VALIDATED_RECEIPT", "view_model.receipts.submission.status", "eq", "VALIDATED", "view_model.receipts.submission.receipt_id"),
    "already-submitted": ("VALIDATED_RECEIPT", "view_model.receipts.submission.duplicate_state", "eq", "EXISTING_RECEIPT", "view_model.receipts.submission.receipt_id"),
    "delivery-delayed": ("PROVIDER_DELIVERY", "view_model.delivery.provider_state", "eq", "DELAYED", "view_model.delivery.last_provider_receipt_id"),
    "delivery-degraded": ("PROVIDER_DELIVERY", "view_model.delivery.provider_state", "eq", "DEGRADED", "view_model.delivery.last_provider_receipt_id"),
    "delivery-failed": ("PROVIDER_DELIVERY", "view_model.delivery.provider_state", "eq", "FAILED", "view_model.delivery.last_provider_receipt_id"),
    "idp-unavailable": ("IDENTITY_PROVIDER", "view_model.identity_provider.health", "eq", "UNAVAILABLE", "view_model.identity_provider.observation_id"),
    "idp-disabled": ("IDENTITY_PROVIDER", "view_model.identity_provider.account_state", "eq", "DISABLED", "view_model.identity_provider.observation_id"),
    "callback-error": ("CALLBACK_RECEIPT", "view_model.callback_receipt.state", "eq", "FAILED", "view_model.callback_receipt.receipt_id"),
    "scan-pending": ("UPLOAD_RECEIPT", "view_model.upload_receipts.scan_state", "eq", "PENDING", "view_model.upload_receipts.last_receipt_id"),
    "upload-scanning": ("UPLOAD_RECEIPT", "view_model.upload_receipts.scan_state", "eq", "SCANNING", "view_model.upload_receipts.last_receipt_id"),
    "uploading": ("UPLOAD_RECEIPT", "view_model.upload_receipts.upload_state", "eq", "UPLOADING", "view_model.upload_receipts.last_receipt_id"),
}


PRIMARY_REFINEMENT_BY_CATEGORY: dict[str, set[str]] = {
    "access": {"unauthorized", "forbidden", "unauthenticated", "session-expired", "blocked"},
    "blocked": {"blocked", "reauth-required", "validation-error", "partial"},
    "conflict": {"conflict", "blocked", "validation-error"},
    "degraded": {"degraded", "offline", "partial", "stale", "error"},
    "empty": {"awaiting-query", "empty", "filtered-empty", "not-found"},
    "failure": {"error", "server-error", "partial-failure", "degraded"},
    "pending": {"loading", "saving", "submitting", "refreshing", "draft"},
    "receipt": {"receipt", "saved", "success"},
    "security": {"blocked", "forbidden", "partial"},
    "stale": {"stale", "session-expiring", "superseded"},
    "success": {"success", "saved", "ready", "current", "healthy"},
    "terminal": {"superseded", "receipt", "not-found", "success"},
    "validation": {"validation-error", "invalid-filter", "blocked", "partial"},
}


def special_signal_contract(state: str, category: str) -> dict[str, Any]:
    code = state.upper().replace("-", "_")
    override = SPECIAL_SIGNAL_OVERRIDES.get(state)
    if override:
        family, path, operator, value, evidence_path = override
        return {
            "signal_family": family,
            "cardinality": "SINGLE_VALUE",
            "all": [
                {"path": path, "op": operator, "value": value},
                {"path": evidence_path, "op": "present"},
            ],
            "runtime_status": "OPEN_IMPLEMENTATION",
        }
    family, path, operator, evidence_root = SPECIAL_SIGNAL_FAMILIES[category]
    return {
        "signal_family": family,
        "cardinality": "MULTI_VALUE_CODE_SET",
        "all": [
            {"path": path, "op": operator, "value": code},
            {"path": f"{evidence_root}.{code}", "op": "present"},
        ],
        "runtime_status": "OPEN_IMPLEMENTATION",
    }


def special_signals_are_mutually_exclusive(
    left: dict[str, Any], right: dict[str, Any]
) -> bool:
    """Only distinct values of the same scalar signal are mutually exclusive."""

    if left["cardinality"] != "SINGLE_VALUE" or right["cardinality"] != "SINGLE_VALUE":
        return False
    left_signal = left["all"][0]
    right_signal = right["all"][0]
    return (
        left["signal_family"] == right["signal_family"]
        and left_signal["path"] == right_signal["path"]
        and left_signal.get("value") != right_signal.get("value")
    )


def exact_focus(screen_id: str, state: str, focus: str) -> dict[str, Any]:
    prefix = snake_screen(screen_id)
    if focus == "preserve":
        return {"behavior": "PRESERVE_ACTIVE_ELEMENT", "target_test_id": None}
    if focus == "main-heading":
        return {"behavior": "MOVE", "target_test_id": f"{prefix}__heading"}
    if focus == "search-input":
        return {
            "behavior": "MOVE",
            "target_test_id": f"{prefix}__state__{state.replace('-', '_')}__search_input",
        }
    return {
        "behavior": "MOVE",
        "target_test_id": f"{prefix}__state__{state.replace('-', '_')}__heading",
    }


def build_state_contracts(
    catalog: dict[str, Any], state_profiles: dict[str, Any]
) -> dict[str, Any]:
    templates: dict[tuple[str, str], dict[str, Any]] = {
        (row["profile"], row["state"]): row for row in state_profiles["templates"]
    }
    special_set = {
        state for screen in catalog["screens"] for state in screen.get("special_states", [])
    }
    if set(SPECIAL_STATE_ROWS) != special_set:
        missing = sorted(special_set - set(SPECIAL_STATE_ROWS))
        extra = sorted(set(SPECIAL_STATE_ROWS) - special_set)
        raise ValueError(f"special-state semantics mismatch: missing={missing}, extra={extra}")
    profile_rows: list[dict[str, Any]] = []
    special_rows: list[dict[str, Any]] = []
    for screen in catalog["screens"]:
        screen_id = screen["id"]
        profile = screen["state_profile"]
        profile_templates = [
            row for row in state_profiles["templates"] if row["profile"] == profile
        ]
        for template in profile_templates:
            state = template["state"]
            preserve = template["preserve"]
            action = template["action_policy"]
            if preserve not in PRESERVE_COPY or action not in ACTION_COPY:
                raise ValueError(f"{profile}::{state}: missing Korean policy copy")
            profile_rows.append(
                {
                    "occurrence_id": f"{screen_id}::profile::{state}",
                    "screen_id": screen_id,
                    "kind": "PROFILE",
                    "profile": profile,
                    "state": state,
                    "trigger": copy.deepcopy(template["trigger"]),
                    "precedence": {
                        "rank": PROFILE_PRECEDENCE[state],
                        "tie_behavior": "FAIL_CLOSED_TO_STATE_CONFLICT",
                        "coexists_with_special_overlay": True,
                    },
                    "preserve": {"policy": preserve, "copy": PRESERVE_COPY[preserve]},
                    "action": {"policy": action, "copy": ACTION_COPY[action]},
                    "focus": exact_focus(screen_id, state, template["focus"]),
                    "live": {
                        "mode": template["live"],
                        "region_test_id": f"{snake_screen(screen_id)}__state_live",
                        "announce_once_per_transition": True,
                    },
                    "retry": {
                        "safety": template["retry_safety"],
                        "same_idempotency_key_only_when_contract_allows": True,
                    },
                    "copy": {
                        "heading": f"{screen['title']} — {PROFILE_STATE_LABELS[state]}",
                        "summary": f"{screen['title']}의 ‘{PROFILE_STATE_LABELS[state]}’ 상태입니다. {screen['primary_job']}",
                        "preservation": PRESERVE_COPY[preserve],
                        "next_step": ACTION_COPY[action],
                    },
                }
            )
        for state in screen.get("special_states", []):
            label, category = SPECIAL_STATE_ROWS[state]
            category_contract = CATEGORY_CONTRACTS[category]
            trigger = special_signal_contract(state, category)
            refinement_states = sorted(
                set(state_profiles["runtime_signal_contract"].get("profiles", {}).get(profile, []))
                & PRIMARY_REFINEMENT_BY_CATEGORY[category]
            )
            if not refinement_states:
                refinement_states = sorted(
                    set(
                        row["state"]
                        for row in state_profiles["templates"]
                        if row["profile"] == profile
                    )
                    & PRIMARY_REFINEMENT_BY_CATEGORY[category]
                )
            sibling_states = list(screen.get("special_states", []))
            compatible_special_states = sorted(
                sibling
                for sibling in sibling_states
                if sibling != state
                and not special_signals_are_mutually_exclusive(
                    trigger,
                    special_signal_contract(sibling, SPECIAL_STATE_ROWS[sibling][1]),
                )
            )
            mutually_exclusive_special_states = sorted(
                sibling
                for sibling in sibling_states
                if sibling != state
                and special_signals_are_mutually_exclusive(
                    trigger,
                    special_signal_contract(sibling, SPECIAL_STATE_ROWS[sibling][1]),
                )
            )
            if category in SPECIAL_FOCUS_BLOCKING_CATEGORIES:
                focus_contract = {
                    "behavior": "MOVE_ON_BLOCKING_USER_TRANSITION",
                    "move_when": {
                        "any": [
                            {"path": "transition.origin", "op": "eq", "value": "USER_ACTION"},
                            {"path": "transition.activeElementBecameDisabled", "op": "eq", "value": True},
                        ]
                    },
                    "otherwise": "PRESERVE_ACTIVE_ELEMENT",
                    "target_test_id": f"{snake_screen(screen_id)}__special__{state.replace('-', '_')}__heading",
                }
            else:
                focus_contract = {
                    "behavior": "PRESERVE_ACTIVE_ELEMENT",
                    "target_test_id": None,
                }
            special_rows.append(
                {
                    "occurrence_id": f"{screen_id}::special::{state}",
                    "screen_id": screen_id,
                    "kind": "SPECIAL",
                    "state": state,
                    "category": category,
                    "trigger": trigger,
                    "precedence": {
                        "rank": category_contract["rank"],
                        "compatible_tie_behavior": "CO_RENDER_ALL_WITH_SHARED_CATEGORY_SUMMARY",
                        "incompatible_tie_behavior": "FAIL_CLOSED_TO_STATE_CONFLICT",
                        "overlays_primary_state": True,
                    },
                    "primary_state_relation": {
                        "disposition": "REFINES_PRIMARY_STATE"
                        if refinement_states
                        else "ORTHOGONAL_OVERLAY",
                        "refines": refinement_states,
                        "rule": "The special signal never selects or replaces the exactly-one primary state.",
                    },
                    "coexistence": {
                        "compatible_special_states": compatible_special_states,
                        "mutually_exclusive_same_family_states": mutually_exclusive_special_states,
                        "same_family_conflict_behavior": "FAIL_CLOSED_TO_STATE_CONFLICT",
                    },
                    "preserve": {"policy": category, "copy": category_contract["preserve"]},
                    "action": {"policy": category, "copy": category_contract["action"]},
                    "focus": focus_contract,
                    "live": {
                        "mode": category_contract["live"],
                        "region_test_id": f"{snake_screen(screen_id)}__special_state_live",
                        "announce_once_per_transition": True,
                    },
                    "retry": {
                        "safety": category_contract["retry"],
                        "same_idempotency_key_only_when_contract_allows": True,
                    },
                    "copy": {
                        "heading": label,
                        "screen_context": screen["primary_job"],
                        "affected_scope_label": screen["title"],
                        "preservation": category_contract["preserve"],
                        "next_step": category_contract["action"],
                        "runtime_detail_status": "OPEN_IMPLEMENTATION",
                    },
                }
            )
    expected_profile_ids = {
        f"{screen['id']}::profile::{row['state']}"
        for screen in catalog["screens"]
        for row in state_profiles["templates"]
        if row["profile"] == screen["state_profile"]
    }
    expected_special_ids = {
        f"{screen['id']}::special::{state}"
        for screen in catalog["screens"]
        for state in screen.get("special_states", [])
    }
    if {row["occurrence_id"] for row in profile_rows} != expected_profile_ids:
        raise ValueError("profile occurrence registry is not set-equal to catalog x profile templates")
    if {row["occurrence_id"] for row in special_rows} != expected_special_ids:
        raise ValueError("special occurrence registry is not set-equal to catalog special states")
    occurrence_ids = [row["occurrence_id"] for row in profile_rows + special_rows]
    if len(occurrence_ids) != len(set(occurrence_ids)):
        raise ValueError("state occurrence IDs are not unique")
    return {
        "schema_version": 1,
        "specification_version": "13.0.0+owner-ui-states.2",
        "status": "OPEN_IMPLEMENTATION",
        "authority_mode": "ADDITIVE_OVERLAY",
        "sources": [
            "specs/ui/screen-catalog.yaml#screens[].state_profile",
            "specs/ui/screen-catalog.yaml#screens[].special_states",
            "specs/ui/state-profile-contracts.yaml#templates",
        ],
        "selection_contract": {
            "primary_state": "Exactly one profile state trigger must be true.",
            "special_overlay": "Zero or more explicitly catalogued special-state triggers may overlay the primary state.",
            "precedence": "Highest rank controls blocker/action emphasis; equal-rank incompatible states fail closed to STATE_CONFLICT.",
            "coexistence": "Different typed signal families may coexist; states in one single-valued family are mutually exclusive.",
            "renderer_inference_forbidden": True,
        },
        "counts": {
            "profile_occurrences": len(profile_rows),
            "special_occurrences": len(special_rows),
            "total_occurrences": len(profile_rows) + len(special_rows),
        },
        "implementation_requirements": [
            "Generate a typed ScreenRuntimeSignalsV1 selector and one test fixture per occurrence_id; renderer-side state inference is forbidden.",
            "Render every non-null focus target and live-region test ID, then assert activeElement and single-announcement behavior.",
            "Persist server acknowledgement before selecting saved or receipt; timers, toasts and HTTP status alone are insufficient.",
            "Exercise conflict and failure rows with preserved input, readable diff, retry fence and support reference in real route tests.",
        ],
        "profile_occurrences": profile_rows,
        "special_occurrences": special_rows,
    }


def navigation_focus_target(
    key: str,
    contract: dict[str, Any],
    screen_by: dict[str, dict[str, Any]],
    manifest_by: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    target = contract["target"]
    fragment_overrides = {
        "PUB-005.compare": ("PUB-005", "diff"),
        "PUB-034.view-status": ("PUB-034", "message"),
    }
    if key in fragment_overrides:
        screen_id, section_id = fragment_overrides[key]
        test_id = next(
            row["test_id"]
            for row in manifest_by[screen_id]["section_order"]
            if row["id"] == section_id
        )
        return {
            "kind": "SECTION_HEADING",
            "screen_id": screen_id,
            "section_id": section_id,
            "test_id": test_id,
            "authority_fragment_alias": target.get("fragment"),
        }
    if isinstance(target, dict) and target.get("screen_id"):
        screen_id = target["screen_id"]
        fragment = target.get("fragment")
        if fragment:
            matches = [
                section
                for section in screen_by[screen_id]["sections"]
                if section["id"] == fragment or section.get("anchor") == fragment
            ]
            if len(matches) != 1:
                raise ValueError(f"{key}: fragment does not resolve to exactly one section")
            section_id = matches[0]["id"]
            test_id = next(
                row["test_id"]
                for row in manifest_by[screen_id]["section_order"]
                if row["id"] == section_id
            )
            return {
                "kind": "SECTION_HEADING",
                "screen_id": screen_id,
                "section_id": section_id,
                "test_id": test_id,
            }
        return {
            "kind": "MAIN_HEADING",
            "screen_id": screen_id,
            "test_id": f"{snake_screen(screen_id)}__heading",
        }
    return {
        "kind": "VALIDATED_DYNAMIC_MAIN_HEADING",
        "resolved_screen_set": sorted(screen_by),
        "runtime_test_id": "resolved_destination.screenTestId + '__heading'",
        "validation": copy.deepcopy(target),
    }


def concrete_test_id_references(value: Any, path: str = "") -> list[tuple[str, str]]:
    references: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else key
            if (
                isinstance(child, str)
                and (key.endswith("test_id") or key == "test_id")
                and re.fullmatch(r"[a-z0-9_]+__[a-z0-9_]+(?:__[a-z0-9_]+)*", child)
            ):
                references.append((child, child_path))
            if isinstance(child, list) and key.endswith("test_ids"):
                for index, item in enumerate(child):
                    if isinstance(item, str) and re.fullmatch(
                        r"[a-z0-9_]+__[a-z0-9_]+(?:__[a-z0-9_]+)*", item
                    ):
                        references.append((item, f"{child_path}[{index}]"))
            references.extend(concrete_test_id_references(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            references.extend(concrete_test_id_references(child, f"{path}[{index}]"))
    return references


def build_dom_ownership_registry(
    catalog: dict[str, Any],
    manifest: dict[str, Any],
    actions: dict[str, Any],
    states: dict[str, Any],
    journeys: dict[str, Any],
    accessibility_contract: dict[str, Any],
    component_overrides: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest_by = {screen["id"]: screen for screen in manifest["screens"]}
    owners: dict[str, dict[str, Any]] = {}

    def own(
        test_id: str,
        screen_id: str,
        owner_component: str,
        owner_scope: str,
        element_role: str,
    ) -> None:
        owner = {
            "test_id": test_id,
            "screen_id": screen_id,
            "owner_component": owner_component,
            "owner_scope": owner_scope,
            "element_role": element_role,
            "runtime_file": manifest_by[screen_id]["implementation_files"]["page"],
            "runtime_status": "OPEN_IMPLEMENTATION",
        }
        existing = owners.get(test_id)
        if existing is not None and existing != owner:
            raise ValueError(f"{test_id}: conflicting DOM owners")
        owners[test_id] = owner

    for screen in catalog["screens"]:
        screen_id = screen["id"]
        prefix = snake_screen(screen_id)
        own(f"{prefix}__heading", screen_id, "RoutePage", "screen", "h1")
        own(f"{prefix}__main", screen_id, "RoutePage", "screen", "main")
        own(f"{prefix}__error_summary", screen_id, "FormErrorSummary", "screen", "alert")
        own(f"{prefix}__state_live", screen_id, "ScreenStateRegion", "screen", "status")
        if screen.get("special_states"):
            own(f"{prefix}__special_state_live", screen_id, "SpecialStateRegion", "screen", "status")
        for row in manifest_by[screen_id]["section_order"]:
            override = component_overrides.get(f"{screen_id}.{row['id']}")
            component = override["component"] if override else row["component"]
            own(row["test_id"], screen_id, component, row["id"], "section-heading")
        for action in screen.get("actions", []):
            own(
                f"{prefix}__action__{action['id'].replace('-', '_')}",
                screen_id,
                "ScreenActions",
                "screen-actions",
                "button-or-link",
            )
            own(
                f"{prefix}__navigation_error__{action['id'].replace('-', '_')}",
                screen_id,
                "NavigationErrorSummary",
                "screen-actions",
                "alert",
            )

    for command in actions["commands"]:
        for placement in command["placements"]:
            screen_id = placement["screen_id"]
            section_id = placement["section_id"]
            component = next(
                row["component"]
                for row in manifest_by[screen_id]["section_order"]
                if row["id"] == section_id
            )
            own(placement["action_test_id"], screen_id, component, section_id, "button")
            own(
                placement["failure_focus_test_id"],
                screen_id,
                "CommandErrorSummary",
                section_id,
                "alert",
            )
            for binding in placement["request_bindings"]:
                if binding["error_test_id"]:
                    own(
                        binding["error_test_id"],
                        screen_id,
                        component,
                        section_id,
                        "field-error",
                    )
            destination = placement["success_destination"]
            own(
                destination["receipt_focus_test_id"],
                destination["screen_id"],
                "DecisionReceipt",
                destination["section_id"],
                "receipt-heading",
            )

    for action in actions["journey_visible_actions"]:
        screen_id = action["screen_id"]
        section_id = action["section_id"]
        component = next(
            row["component"]
            for row in manifest_by[screen_id]["section_order"]
            if row["id"] == section_id
        )
        own(action["action_test_id"], screen_id, component, section_id, "link-or-button")

    for occurrence in states["profile_occurrences"]:
        target = occurrence["focus"].get("target_test_id")
        if target and target not in owners:
            own(
                target,
                occurrence["screen_id"],
                "ScreenStateRegion",
                "primary-state",
                "state-heading",
            )
    for occurrence in states["special_occurrences"]:
        target = occurrence["focus"].get("target_test_id")
        if target and target not in owners:
            own(
                target,
                occurrence["screen_id"],
                "SpecialStateRegion",
                "special-state",
                "state-heading",
            )

    for journey in journeys["journeys"]:
        for edge in journey["edges"]:
            for destination in edge["destinations"]:
                if edge["to_node_kind"] != "SCREEN" and destination["focus_test_id"] not in owners:
                    own(
                        destination["focus_test_id"],
                        destination["screen_id"],
                        "JourneyOutcomeStatus",
                        edge["edge_id"],
                        "outcome-heading",
                    )

    priority_owners = {
        "pub_004__evidence_drawer__heading": ("PUB-004", "EvidenceLedger", "evidence", "dialog-heading"),
        "rsp_005__field_error__answers": ("RSP-005", "CheckAnswers", "answers", "field-error"),
        "rsp_005__field_error__attachments": ("RSP-005", "FileUploadQueue", "attachments", "field-error"),
        "rsp_005__field_error__consent": ("RSP-005", "GuidedFormSection", "consent", "field-error"),
        "rsp_005__field_error__authority": ("RSP-005", "GuidedFormSection", "authority", "field-error"),
        "rsp_006__appeal__heading": ("RSP-006", "GuidedFormSection", "next", "dialog-heading"),
        "rsp_006__action__create_response_appeal": ("RSP-006", "GuidedFormSection", "next", "button"),
        "cas_011__proposal_detail__heading": ("CAS-011", "AgentSuggestionPanel", "decisions", "dialog-heading"),
        "cas_011__proposal_row__selected": ("CAS-011", "AgentSuggestionPanel", "decisions", "row"),
        "rev_002__decision_reason": ("REV-002", "DecisionReviewPanel", "decision", "dialog-heading"),
        "rev_003__reauth__heading": ("REV-003", "ReauthPrompt", "reauth", "dialog-heading"),
        "ops_006__approval__heading": ("OPS-006", "DecisionReviewPanel", "approval", "dialog-heading"),
        "rsp_005__special__submit_conflict__heading": ("RSP-005", "SpecialStateRegion", "special-state", "state-heading"),
    }
    for test_id, (screen_id, component, scope, role) in priority_owners.items():
        own(test_id, screen_id, component, scope, role)

    source_documents = {
        "actions": actions,
        "states": states,
        "journeys": journeys,
        "accessibility": accessibility_contract,
    }
    references = [
        (test_id, f"{document_name}.{path}")
        for document_name, document in source_documents.items()
        for test_id, path in concrete_test_id_references(document)
    ]
    missing = sorted({test_id for test_id, _ in references} - set(owners))
    if missing:
        raise ValueError(f"focus/live/test references lack exact DOM ownership: {missing}")
    paths_by_id: dict[str, list[str]] = {}
    for test_id, path in references:
        paths_by_id.setdefault(test_id, []).append(path)
    rows: list[dict[str, Any]] = []
    for test_id in sorted(paths_by_id):
        paths = sorted(set(paths_by_id[test_id]))
        rows.append(
            {
                **owners[test_id],
                "reference_paths": paths,
                "usage_kinds": sorted(
                    {
                        "LIVE_REGION" if "live" in path.lower() else "FOCUS_OR_TEST_TARGET"
                        for path in paths
                    }
                ),
            }
        )
    live_references = [row for row in references if "live" in row[1].lower()]
    focus_references = [row for row in references if "live" not in row[1].lower()]
    return rows, {
        "concrete_reference_occurrences": len(references),
        "concrete_owned_ids": len(rows),
        "focus_reference_occurrences": len(focus_references),
        "focus_owned_ids": len({test_id for test_id, _ in focus_references}),
        "live_reference_occurrences": len(live_references),
        "live_owned_ids": len({test_id for test_id, _ in live_references}),
        "missing_owner_ids": 0,
        "runtime_implemented_owner_ids": 0,
        "runtime_status": "OPEN_IMPLEMENTATION",
    }


def build_accessibility_contracts(
    catalog: dict[str, Any],
    manifest: dict[str, Any],
    navigation: dict[str, Any],
    actions: dict[str, Any],
    states: dict[str, Any],
    journeys: dict[str, Any],
    component_overrides: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    screen_by = {screen["id"]: screen for screen in catalog["screens"]}
    manifest_by = {screen["id"]: screen for screen in manifest["screens"]}
    screen_rows: list[dict[str, Any]] = []
    for screen in catalog["screens"]:
        screen_id = screen["id"]
        roles = dict(
            zip(
                ("object", "state", "answer", "evidence", "unknown", "next_action"),
                SCREEN_SECTION_ROLES[screen_id],
                strict=True,
            )
        )
        document_order = [row["id"] for row in manifest_by[screen_id]["section_order"]]
        summary_order = [
            {"semantic": semantic, "section_id": roles[semantic]}
            for semantic in ("object", "state", "answer", "unknown", "evidence", "next_action")
        ]
        screen_rows.append(
            {
                "screen_id": screen_id,
                "route": screen["route"],
                "heading_test_id": f"{snake_screen(screen_id)}__heading",
                "document_section_order": document_order,
                "authority_above_fold_order": list(screen["above_fold_order"]),
                "ten_second_summary_order": summary_order,
                "landmarks": ["banner", "navigation", "main", "contentinfo"]
                if screen["surface"] == "public"
                else ["banner", "navigation", "main"],
                "heading_contract": {
                    "h1_count": 1,
                    "section_heading_level": 2,
                    "nested_heading_rule": "No skipped levels; visual size never selects semantic level.",
                },
                "responsive_transformations": [
                    {
                        "check": "320x568",
                        "container_mode": "COMPACT_SINGLE_COLUMN",
                        "summary_order": summary_order,
                        "document_order": document_order,
                        "table_mode": "LABELLED_STACKED_ROWS_OR_LABELLED_TWO_DIMENSIONAL_SCROLL_REGION",
                        "sticky_action": "bottom action may be sticky only with keyboard and safe-area clearance",
                        "page_horizontal_overflow": "FORBIDDEN",
                        "section_placements": [
                            {
                                "section_id": section_id,
                                "grid_column": "1 / -1",
                                "visual_order": index,
                                "available": True,
                            }
                            for index, section_id in enumerate(document_order, start=1)
                        ],
                    },
                    {
                        "check": "768x1024",
                        "container_mode": "MEDIUM_REFLOW",
                        "screen_specific_layout_statement": screen["layout_contract"]["medium"],
                        "summary_order": summary_order,
                        "document_order": document_order,
                        "page_horizontal_overflow": "FORBIDDEN",
                        "section_placements": [
                            {
                                "section_id": section_id,
                                "grid_area": f"{snake_screen(screen_id)}--{section_id.replace('-', '_')}",
                                "grid_column": "1 / -1",
                                "visual_order": index,
                                "available": True,
                                "sticky": False,
                            }
                            for index, section_id in enumerate(document_order, start=1)
                        ],
                    },
                    {
                        "check": "1440x900",
                        "container_mode": "WIDE_AUTHORITY_LAYOUT",
                        "screen_specific_layout_statement": screen["layout_contract"]["wide"],
                        "summary_order": summary_order,
                        "document_order": document_order,
                        "reading_measure": "<=72ch for prose",
                        "section_placements": [
                            {
                                "section_id": section_id,
                                "grid_area": f"{snake_screen(screen_id)}--{section_id.replace('-', '_')}",
                                "grid_column": "1 / -1",
                                "visual_order": index,
                                "available": True,
                                "sticky": False,
                            }
                            for index, section_id in enumerate(document_order, start=1)
                        ],
                    },
                    {
                        "check": "1280x1024@200%",
                        "effective_css_viewport": "640x512",
                        "container_mode": "MEDIUM_REFLOW",
                        "summary_order": summary_order,
                        "document_order": document_order,
                        "fixed_overlay_obscures_content": False,
                        "page_horizontal_overflow": "FORBIDDEN",
                        "section_placements": [
                            {
                                "section_id": section_id,
                                "grid_column": "1 / -1",
                                "visual_order": index,
                                "available": True,
                            }
                            for index, section_id in enumerate(document_order, start=1)
                        ],
                    },
                    {
                        "check": "1280x1024@400%",
                        "effective_css_viewport": "320x256",
                        "container_mode": "COMPACT_SINGLE_COLUMN",
                        "summary_order": summary_order,
                        "document_order": document_order,
                        "fixed_overlay_obscures_content": False,
                        "page_horizontal_overflow": "FORBIDDEN",
                        "section_placements": [
                            {
                                "section_id": section_id,
                                "grid_column": "1 / -1",
                                "visual_order": index,
                                "available": True,
                            }
                            for index, section_id in enumerate(document_order, start=1)
                        ],
                    },
                ],
                "interaction_contract": {
                    "minimum_target_css_px": "44x44 except adequately separated inline links",
                    "skip_link_target_test_id": f"{snake_screen(screen_id)}__main",
                    "error_summary_test_id": f"{snake_screen(screen_id)}__error_summary",
                    "dialog_restore_default_test_id": f"{snake_screen(screen_id)}__action__{str(screen.get('primary_action_id', 'none')).replace('-', '_')}",
                    "reduced_motion": "remove non-essential movement without removing state or completion feedback",
                    "live_region_test_id": f"{snake_screen(screen_id)}__state_live",
                },
            }
        )
    nav_rows: list[dict[str, Any]] = []
    for key, contract in navigation["navigation_contracts"].items():
        screen_id, action_id = key.split(".", 1)
        nav_rows.append(
            {
                "navigation_key": key,
                "source_action_test_id": f"{snake_screen(screen_id)}__action__{action_id.replace('-', '_')}",
                "arrival_focus": navigation_focus_target(key, contract, screen_by, manifest_by),
                "invalid_or_denied_focus": {
                    "test_id": f"{snake_screen(screen_id)}__navigation_error__{action_id.replace('-', '_')}",
                    "restore_action_test_id": f"{snake_screen(screen_id)}__action__{action_id.replace('-', '_')}",
                    "announcement": "assertive-once-without-protected-object-detail",
                },
                "history_restore_focus_test_id": f"{snake_screen(screen_id)}__action__{action_id.replace('-', '_')}",
            }
        )
    if len(screen_rows) != 94 or len(nav_rows) != 108:
        raise ValueError("responsive or navigation focus source set changed")
    document = {
        "schema_version": 1,
        "specification_version": "13.0.0+owner-ui-a11y.2",
        "status": "OPEN_IMPLEMENTATION",
        "authority_mode": "ADDITIVE_OVERLAY",
        "conformance": "WCAG 2.2 AA",
        "sources": [
            "specs/ui/screen-catalog.yaml",
            "specs/ui/screen-build-manifest.yaml",
            "specs/ui/navigation-action-contracts.yaml",
        ],
        "set_equality": {
            "screen_contracts": 94,
            "navigation_focus_contracts": 108,
            "required_viewport_zoom_checks_per_screen": 5,
        },
        "global_rules": [
            "DOM, heading and screen-reader order never changes across breakpoints or zoom.",
            "State, blocker, answer, unknown, evidence and next action remain reachable before secondary detail.",
            "No page-level two-dimensional scrolling, clipped text, obscured focus or keyboard trap is permitted.",
            "Live announcements occur once and never move focus; blocking validation moves focus to its exact summary or heading.",
        ],
        "implementation_requirements": [
            "Render every declared heading, main, error-summary, state-live, action and navigation focus test ID and validate set equality against this contract.",
            "Capture DOM-order and visual evidence at all five declared viewport/zoom checks for every screen; no required region may be hidden or detached.",
            "Add Playwright activeElement assertions for entry, validation, conflict, receipt, navigation, dialog, drawer and async completion.",
            "Run pinned NVDA+Firefox and VoiceOver+Safari critical-journey checks in addition to axe, keyboard, reflow and visual tests.",
        ],
        "priority_interaction_focus": [
            {
                "interaction": "PUB-004.open-evidence drawer",
                "initial_focus_test_id": "pub_004__evidence_drawer__heading",
                "close_restore_test_id": "pub_004__action__open_evidence",
                "escape": "close only when no unsaved annotation exists",
            },
            {
                "interaction": "RSP-005 validation summary",
                "initial_focus_test_id": "rsp_005__error_summary",
                "field_link_test_ids": [
                    "rsp_005__field_error__answers",
                    "rsp_005__field_error__attachments",
                    "rsp_005__field_error__consent",
                    "rsp_005__field_error__authority",
                ],
                "close_restore_test_id": "rsp_005__action__submit",
            },
            {
                "interaction": "RSP-006 appeal form",
                "initial_focus_test_id": "rsp_006__appeal__heading",
                "close_restore_test_id": "rsp_006__action__create_response_appeal",
                "escape": "close only after preserving entered appeal fields",
            },
            {
                "interaction": "CAS-011 proposal detail",
                "initial_focus_test_id": "cas_011__proposal_detail__heading",
                "close_restore_test_id": "cas_011__proposal_row__selected",
                "escape": "close and restore the exact selected proposal row",
            },
            {
                "interaction": "REV-002 reason dialog",
                "initial_focus_test_id": "rev_002__decision_reason",
                "close_restore_test_id": "rev_002__action__request_changes",
                "escape": "preserve reason draft and close before submission",
            },
            {
                "interaction": "REV-003 action-bound reauthentication",
                "initial_focus_test_id": "rev_003__reauth__heading",
                "close_restore_test_id": "rev_003__action__publish",
                "escape": "cancel only the authorization attempt and preserve publication context",
            },
            {
                "interaction": "OPS-006 approval dialog",
                "initial_focus_test_id": "ops_006__approval__heading",
                "close_restore_test_id": "ops_006__action__activate",
                "escape": "preserve proposal draft and close before authorization",
            },
        ],
        "screens": screen_rows,
        "navigation_focus_contracts": nav_rows,
    }
    ownership_rows, ownership_counts = build_dom_ownership_registry(
        catalog,
        manifest,
        actions,
        states,
        journeys,
        document,
        component_overrides,
    )
    document["dom_ownership_set_equality"] = ownership_counts
    document["dom_ownership_registry"] = ownership_rows
    return document



def build_documents() -> dict[str, dict[str, Any]]:
    catalog = load_yaml(UI / "screen-catalog.yaml")
    manifest = load_yaml(UI / "screen-build-manifest.yaml")
    data = load_yaml(UI / "screen-data-contracts.yaml")
    addendum_operations = load_yaml(PRODUCT / "addendum-operation-contracts.yaml")
    journey_authority = load_yaml(PRODUCT / "addendum-journey-contracts.yaml")
    resources = load_yaml(PRODUCT / "addendum-resource-error-contracts.yaml")
    base_resources = load_yaml(API / "resource-schemas.yaml")
    navigation = load_yaml(UI / "navigation-action-contracts.yaml")
    state_profiles = load_yaml(UI / "state-profile-contracts.yaml")
    archetypes = load_yaml(UI / "page-archetypes.yaml")
    component_catalog = load_yaml(UI / "component-catalog.yaml")
    section_surface_overrides = load_yaml(UI / "section-surface-overrides.yaml")
    component_by = {
        component["id"]: component for component in component_catalog["components"]
    }
    screen_by = {screen["id"]: screen for screen in catalog["screens"]}
    for screen_id, refinement in PRIORITY_SCREEN_REFINEMENTS.items():
        section_ids = {section["id"] for section in screen_by[screen_id]["sections"]}
        for section_id, override in refinement.get("component_overrides", {}).items():
            if section_id not in section_ids:
                raise ValueError(f"{screen_id}.{section_id}: component override section missing")
            component = component_by.get(override["component"])
            if component is None or override["variant"] not in component["variants"]:
                raise ValueError(f"{screen_id}.{section_id}: invalid component override")
    effective = build_effective_contracts(
        catalog,
        manifest,
        archetypes,
        data,
        addendum_operations,
        resources,
        base_resources,
        component_catalog,
        section_surface_overrides,
    )
    actions = build_action_contracts(catalog, manifest, addendum_operations, resources)
    states = build_state_contracts(catalog, state_profiles)
    journeys = build_canonical_journey_contracts(
        journey_authority,
        catalog,
        data,
        addendum_operations,
        actions,
        navigation,
        JOURNEY_OPERATION_ACTION_OVERRIDES,
    )
    accessibility = build_accessibility_contracts(
        catalog,
        manifest,
        navigation,
        actions,
        states,
        journeys,
        {
            **section_surface_overrides["overrides"],
            **section_surface_overrides.get("semantic_overrides", {}),
        },
    )
    return {
        "effective": effective,
        "actions": actions,
        "states": states,
        "accessibility": accessibility,
        "journeys": journeys,
    }


def render(document: dict[str, Any]) -> str:
    return yaml.safe_dump(document, sort_keys=False, allow_unicode=True, width=120)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    parser.add_argument(
        "--target",
        action="append",
        choices=sorted(TARGETS),
        help="generate or check only the named document (repeatable)",
    )
    args = parser.parse_args()
    documents = build_documents()
    failures: list[str] = []
    selected = set(args.target or documents)
    for name, document in documents.items():
        if name not in selected:
            continue
        path = TARGETS[name]
        output = render(document)
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != output:
                failures.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(output, encoding="utf-8")
    if failures:
        print("generated UI contracts differ:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
