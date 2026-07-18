BEGIN;
-- Source-derived 0029 physical registry: 24 relations in canonical creation order.
-- Existing 0001..0024 migrations are immutable; this migration is additive.
DO $$ BEGIN CREATE TYPE editorial.funding_concentration_band AS ENUM ( 'UNKNOWN', 'LE_5_PERCENT', 'GT_5_TO_15_PERCENT', 'GT_15_TO_25_PERCENT', 'GT_25_PERCENT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE editorial.funding_concentration_band FROM PUBLIC;
GRANT USAGE ON TYPE editorial.funding_concentration_band TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE editorial.funding_disclosure_unknown_reason AS ENUM ( 'DENOMINATOR_UNKNOWN', 'GROUPING_DISPUTED', 'MULTIPLE_UNKNOWN_CAUSES' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE editorial.funding_disclosure_unknown_reason FROM PUBLIC;
GRANT USAGE ON TYPE editorial.funding_disclosure_unknown_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE editorial.funding_identity_disclosure_mode AS ENUM ( 'NAMED', 'CATEGORY_ONLY', 'WITHHELD_LEGAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE editorial.funding_identity_disclosure_mode FROM PUBLIC;
GRANT USAGE ON TYPE editorial.funding_identity_disclosure_mode TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE editorial.funding_identity_withholding_reason AS ENUM ( 'BELOW_NAMING_THRESHOLD', 'LEGAL_RESTRICTION', 'PRIVACY_RESTRICTION', 'REVIEWED_CONFIDENTIALITY_DUTY' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE editorial.funding_identity_withholding_reason FROM PUBLIC;
GRANT USAGE ON TYPE editorial.funding_identity_withholding_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE editorial.funding_quorum_class AS ENUM ( 'STANDARD', 'OVERSIGHT', 'BOARD', 'RELATED_PARTY', 'OVERSIGHT_RELATED_PARTY', 'BOARD_RELATED_PARTY' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE editorial.funding_quorum_class FROM PUBLIC;
GRANT USAGE ON TYPE editorial.funding_quorum_class TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.accounting_correction_kind AS ENUM ( 'ADJUSTMENT', 'REPLACEMENT', 'REVERSAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.accounting_correction_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.accounting_correction_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.accounting_correction_reason AS ENUM ( 'LATE_PROVIDER_INVOICE', 'FX_CORRECTION', 'USAGE_CORRECTION', 'TAX_CORRECTION', 'REFUND', 'CREDIT', 'ALLOCATION_CORRECTION', 'SERVICE_CREDIT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.accounting_correction_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.accounting_correction_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.accounting_fact_kind AS ENUM ( 'COST_EVENT', 'COST_ALLOCATION', 'INVOICE_FACT', 'INVOICE_LINE_FACT', 'REVENUE_FACT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.accounting_fact_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.accounting_fact_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.accounting_scope_kind AS ENUM ( 'DEPLOYMENT', 'ORGANIZATION' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.accounting_scope_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.accounting_scope_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.accounting_target_amount_kind AS ENUM ( 'COST_EVENT_AMOUNT', 'COST_ALLOCATION_ALLOCATED_AMOUNT', 'COST_ALLOCATION_UNALLOCATED_AMOUNT', 'INVOICE_TOTAL', 'INVOICE_LINE_TOTAL', 'REVENUE_AMOUNT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.accounting_target_amount_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.accounting_target_amount_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.acquisition_attribution_state AS ENUM ( 'ATTRIBUTED', 'UNATTRIBUTED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.acquisition_attribution_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.acquisition_attribution_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.billable_metric AS ENUM ( 'ACTIVE_CONTRIBUTOR', 'PROCESSING_CREDIT', 'STORAGE_GB_MONTH', 'API_RECORD_UNIT', 'INCLUDED_DELIVERY', 'INCLUDED_EXPORT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.billable_metric FROM PUBLIC;
GRANT USAGE ON TYPE ops.billable_metric TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.billable_unit AS ENUM ( 'CONTRIBUTOR_MONTH', 'CREDIT', 'GB_MONTH', 'KILO_RECORDS', 'ATTEMPT', 'BYTE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.billable_unit FROM PUBLIC;
GRANT USAGE ON TYPE ops.billable_unit TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_activation_observation_state AS ENUM ( 'ACTIVATED_ON_TIME', 'ACTIVATED_LATE', 'MATURED_NOT_ACTIVATED', 'RIGHT_CENSORED', 'UNKNOWN' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_activation_observation_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_activation_observation_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_breach_action AS ENUM ( 'NONE', 'COMPLETE_QUALIFICATION', 'CLOSE_ATTRIBUTION', 'REVIEW_COHORT_LOSS', 'COMPLETE_CONFIGURATION', 'REPAIR_DATA_READINESS', 'VERIFY_PAID_PACKET', 'RECOVER_VALUE_WORKFLOW', 'RECONCILE_USAGE_AND_INVOICE', 'RECONCILE_REVENUE', 'CLOSE_COST_AND_FX_GAPS', 'ADJUST_PRICE_QUOTA_OR_EFFICIENCY', 'RESTORE_SUPPORT_CAPACITY', 'RESTORE_SLA_AND_TELEMETRY', 'CONTAIN_TRUST_INCIDENT', 'REVIEW_PRODUCT_PAUSE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_breach_action FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_breach_action TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_id AS ENUM ( 'BM-ACQ-QUALIFIED-ORG-COUNT', 'BM-ACQ-CHANNEL-MIX', 'BM-FUNNEL-CONFIGURATION-RATE', 'BM-FUNNEL-DATA-READY-RATE', 'BM-VALUE-PAID-MVW', 'BM-VALUE-PAID-MVW-PER-ACTIVE-ORG', 'BM-ACTIVATION-7D-RATE', 'BM-ACTIVATION-TTFPV-P90', 'BM-RETENTION-D29-56-RATE', 'BM-RETENTION-AT-RISK-ORG-COUNT', 'BM-RETENTION-CHURN-RATE', 'BM-FUNNEL-PILOT-TO-PAID-RATE', 'BM-REVENUE-QUALIFIED-ORG-COUNT', 'BM-EXPANSION-ELIGIBILITY-RATE', 'BM-RENEWAL-ELIGIBILITY-RATE', 'BM-REVENUE-RECOGNIZED-KRW', 'BM-BILLING-RECONCILIATION-COVERAGE', 'BM-MARGIN-VARIABLE-GROSS-RATE', 'BM-MARGIN-CONTRIBUTION-KRW', 'BM-COST-PER-PAID-MVW-KRW', 'BM-CAC-KRW', 'BM-CAC-PAYBACK-MONTHS', 'BM-SLA-AVAILABILITY-RATE', 'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG', 'BM-TRUST-HARD-STOP-COUNT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_id FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_id TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_reason AS ENUM ( 'TRUST_REVIEW_OPEN', 'CORRECTION_CHAIN_AMBIGUOUS', 'CONTRACT_NOT_CURRENT', 'RIGHTS_NOT_CURRENT', 'CONFIGURATION_MISMATCH', 'SNAPSHOT_EMPTY_OR_UNREPRODUCIBLE', 'SOURCE_MISSING', 'SOURCE_PARTIAL', 'SOURCE_STALE', 'TERMINAL_RECEIPT_MISSING', 'PACKET_PROOF_INCOMPLETE', 'USAGE_UNKNOWN', 'INVOICE_MEMBERSHIP_GAP', 'REVENUE_CHAIN_INVALID', 'COST_CAPTURE_INCOMPLETE', 'FX_MISSING_OR_STALE', 'SLA_TELEMETRY_GAP', 'ATTRIBUTION_UNKNOWN', 'NONPOSITIVE_CONTRIBUTION', 'DENOMINATOR_ZERO', 'COHORT_NOT_MATURE', 'SAMPLE_TOO_SMALL', 'CAPABILITY_NOT_OFFERED', 'NONE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_sample_disclosure AS ENUM ( 'COUNTS_ONLY', 'RATE_WITH_WILSON_95', 'AUTOMATION_ELIGIBLE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_sample_disclosure FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_sample_disclosure TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_status AS ENUM ( 'KNOWN', 'UNKNOWN', 'NOT_APPLICABLE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_status FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_status TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_threshold_state AS ENUM ( 'NOT_EVALUATED', 'PASS', 'BREACH' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_threshold_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_threshold_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_metric_unit AS ENUM ( 'organizations', 'organizations_by_source_kind', 'verified_workflows', 'workflows_per_organization', 'ratio', 'hours', 'KRW', 'KRW_per_verified_workflow', 'months', 'hours_per_organization_month', 'incidents' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_metric_unit FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_metric_unit TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_stage AS ENUM ( 'QUALIFIED', 'CONFIGURED', 'DATA_READY', 'FIRST_PAID_VALUE', 'ACTIVATED', 'RETAINED', 'AT_RISK', 'CHURNED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_stage FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_stage TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.business_stage_state AS ENUM ( 'KNOWN', 'BLOCKED', 'UNKNOWN', 'NOT_APPLICABLE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.business_stage_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.business_stage_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_contract_status AS ENUM ( 'ACTIVE', 'SUSPENDED', 'ENDED', 'CANCELLED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_contract_status FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_contract_status TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_period_fact_effect AS ENUM ( 'ORIGINAL', 'REPLACEMENT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_period_fact_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_period_fact_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_provisioning_state AS ENUM ( 'UNPROVISIONED', 'PROVISIONED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_provisioning_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_provisioning_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_qualification_reason AS ENUM ( 'QUALIFICATION_ACCEPTED', 'SOURCE_CORRECTION', 'SOURCE_REVERSAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_qualification_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_qualification_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_qualification_receipt_effect AS ENUM ( 'ORIGINAL', 'REPLACEMENT', 'REVERSAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_qualification_receipt_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_qualification_receipt_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.commercial_sku AS ENUM ( 'EVIDENCE_WORKSPACE_ORGANIZATION_V1' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.commercial_sku FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_sku TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.discount_reason AS ENUM ( 'CONTRACTED', 'NONPROFIT', 'VOLUME', 'SERVICE_CREDIT', 'PROMOTIONAL', 'CORRECTION' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.discount_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.discount_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.discount_state AS ENUM ( 'ACTIVE', 'WITHDRAWN' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.discount_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.discount_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_amount_basis AS ENUM ( 'RECOGNIZED', 'BINDING_COMMITTED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_amount_basis FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_amount_basis TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_concentration_unknown_reason AS ENUM ( 'DENOMINATOR_UNKNOWN', 'GROUPING_DISPUTED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_concentration_unknown_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_concentration_unknown_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_denominator_state AS ENUM ( 'APPROVED', 'UNKNOWN' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_denominator_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_denominator_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_denominator_unknown_reason AS ENUM ( 'MISSING', 'ZERO', 'APPROVAL_MISSING', 'APPROVAL_STALE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_denominator_unknown_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_denominator_unknown_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_grouping_dispute_reason AS ENUM ( 'IDENTITY_AMBIGUOUS', 'MEMBER_SET_DISPUTED', 'RELATED_PARTY_STATUS_DISPUTED', 'AUTHORITATIVE_SOURCE_CONFLICT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_grouping_dispute_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_grouping_dispute_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_grouping_state AS ENUM ( 'RESOLVED', 'DISPUTED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_grouping_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_grouping_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_snapshot_row_kind AS ENUM ( 'SNAPSHOT_HEADER', 'COUNTERPARTY_ENTRY' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_snapshot_row_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_snapshot_row_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.funding_source_kind AS ENUM ( 'DONATION', 'GRANT', 'INSTITUTIONAL_CUSTOMER_REVENUE', 'COMMERCIAL_CUSTOMER_REVENUE', 'SPONSORSHIP', 'OTHER_REVIEWED', 'MIXED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.funding_source_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.funding_source_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.fx_correction_reason AS ENUM ( 'SOURCE_RESTATEMENT', 'SOURCE_WITHDRAWAL', 'MANUAL_RECONCILIATION' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.fx_correction_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.fx_correction_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.fx_fact_kind AS ENUM ( 'OBSERVATION', 'REPLACEMENT', 'WITHDRAWAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.fx_fact_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.fx_fact_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.fx_rate_kind AS ENUM ( 'TRANSACTION', 'DAILY_CLOSE', 'CONTRACTUAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.fx_rate_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.fx_rate_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.invoice_fact_effect AS ENUM ( 'ORIGINAL', 'RESTATEMENT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.invoice_fact_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.invoice_fact_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.invoice_usage_membership_effect AS ENUM ( 'ORIGINAL', 'RESTATEMENT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.invoice_usage_membership_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.invoice_usage_membership_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.invoice_usage_membership_kind AS ENUM ( 'ZERO_USAGE', 'INCLUDED_ALLOWANCE', 'BILLED_OVERAGE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.invoice_usage_membership_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.invoice_usage_membership_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.offer_capability_code AS ENUM ( 'PUBLIC_WEB', 'VERIFIED_EMAIL', 'API_EXPORT', 'SIGNED_WEBHOOK', 'DAILY_DIGEST', 'WEEKLY_DIGEST', 'SMS', 'TELEGRAM', 'WHATSAPP', 'LINE', 'KAKAO', 'VOICE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.offer_capability_code FROM PUBLIC;
GRANT USAGE ON TYPE ops.offer_capability_code TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.offer_capability_state AS ENUM ( 'INCLUDED_REQUIRED', 'NOT_OFFERED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.offer_capability_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.offer_capability_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.offer_overage_policy AS ENUM ( 'DECLARED_TARIFF_OVERAGE', 'HARD_LIMIT_NO_OVERAGE', 'NOT_APPLICABLE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.offer_overage_policy FROM PUBLIC;
GRANT USAGE ON TYPE ops.offer_overage_policy TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.offer_quota_kind AS ENUM ( 'NOT_METERED', 'API_RECORD_UNIT', 'DELIVERY_ATTEMPT', 'DIGEST_DISPATCH', 'WEBHOOK_DISPATCH' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.offer_quota_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.offer_quota_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_evidence_member_category AS ENUM ( 'AUTHORIZED_DATASET_SNAPSHOT', 'SOURCE_RIGHTS', 'CAPABILITY_ACTIVATION', 'EXTRACTION_AND_TRANSFORMATION_LINEAGE', 'REPRODUCTION_AND_COMPARISON_INPUT', 'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE', 'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE', 'AI_PROVENANCE_WHEN_CONTRIBUTED', 'HUMAN_DECISION', 'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_evidence_member_category FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_evidence_member_category TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_evidence_packet_state AS ENUM ( 'AWAITING_TERMINAL_BINDING', 'FINALIZED', 'INVALIDATED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_evidence_packet_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_evidence_packet_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_evidence_subject_kind AS ENUM ( 'AUDITED_DELIVERY', 'COMPLETED_DECISION_CYCLE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_evidence_subject_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_evidence_subject_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_packet_invalidation_authority_kind AS ENUM ( 'COMMERCIAL_QUALIFICATION_RECEIPT', 'COMMERCIAL_CONTRACT_PERIOD', 'OUTCOME_FACT_CORRECTION', 'REVIEW_SNAPSHOT', 'TERMINAL_RECEIPT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_packet_invalidation_authority_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_packet_invalidation_authority_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_packet_invalidation_reason AS ENUM ( 'QUALIFICATION_REVERSED', 'CONTRACT_REPLACED', 'SUBJECT_CORRECTED', 'MEMBER_AUTHORITY_REVERSED', 'TERMINAL_SUBJECT_MISMATCH' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_packet_invalidation_reason FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_packet_invalidation_reason TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_terminal_receipt_kind AS ENUM ( 'OUTBOUND_DELIVERY', 'ORGANIZATION_DECISION' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_terminal_receipt_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_terminal_receipt_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.paid_terminal_resulting_state AS ENUM ( 'DELIVERED', 'READ', 'REJECTED_FINAL', 'EFFECT_SUCCEEDED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.paid_terminal_resulting_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_terminal_resulting_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.sla_offer_state AS ENUM ( 'UNCONFIGURED_NOT_SOLD', 'CONFIGURED_FOR_SALE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.sla_offer_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.sla_offer_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.sla_selection_state AS ENUM ( 'UNAVAILABLE_NOT_SOLD', 'AVAILABLE_NOT_SELECTED', 'SELECTED' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.sla_selection_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.sla_selection_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.tariff_stage AS ENUM ( 'PILOT', 'GENERAL_AVAILABILITY' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.tariff_stage FROM PUBLIC;
GRANT USAGE ON TYPE ops.tariff_stage TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_fact_effect AS ENUM ( 'ORIGINAL', 'REPLACEMENT', 'REVERSAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_fact_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_fact_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_measurement_state AS ENUM ( 'COMPLETE', 'PARTIAL', 'UNKNOWN' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_measurement_state FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_measurement_state TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_meter_kind AS ENUM ( 'SEAT', 'AGENT_TOKEN', 'MODEL_REQUEST', 'SOURCE_PAGE', 'STORAGE_BYTE_HOUR', 'DELIVERY_ATTEMPT', 'EXPORT_BYTE', 'API_REQUEST' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_meter_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_meter_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_normalization_basis_kind AS ENUM ( 'ACTIVE_CONTRIBUTOR_COUNT', 'AGENT_TOKEN_COUNT', 'MODEL_REQUEST_COST_UNIT', 'SOURCE_PAGE_COUNT', 'ENCRYPTED_BYTE_HOUR', 'DELIVERY_ATTEMPT_COUNT', 'EXPORT_BYTE_COUNT', 'API_RECORD_RETURNED_COUNT' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_normalization_basis_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_normalization_basis_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_receipt_effect AS ENUM ( 'ORIGINAL', 'REPLACEMENT', 'REVERSAL' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_receipt_effect FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_receipt_effect TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_receipt_kind AS ENUM ( 'IDENTITY_USAGE_WINDOW', 'AGENT_USAGE_WINDOW', 'MODEL_USAGE_WINDOW', 'SOURCE_USAGE_WINDOW', 'STORAGE_USAGE_WINDOW', 'DELIVERY_USAGE_WINDOW', 'EXPORT_USAGE_WINDOW', 'API_USAGE_WINDOW' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_receipt_kind FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_receipt_kind TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
DO $$ BEGIN CREATE TYPE ops.usage_unit AS ENUM ( 'COUNT', 'TOKEN', 'REQUEST', 'PAGE', 'BYTE_HOUR', 'ATTEMPT', 'BYTE' ); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
REVOKE ALL ON TYPE ops.usage_unit FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_unit TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
CREATE TYPE ops.funding_snapshot_import_v1 AS (idempotency_key text, snapshot_batch_id uuid, expected_prior_header_id uuid, expected_prior_snapshot_digest char(64), fiscal_year integer, as_of timestamptz, reporting_currency char(3), funding_policy_version text, funding_policy_digest char(64), fx_snapshot_digest char(64), denominator_state ops.funding_denominator_state, denominator_amount numeric(24,6), denominator_unknown_reason ops.funding_denominator_unknown_reason, denominator_approval_digest char(64), denominator_approver_set_digest char(64), denominator_approved_at timestamptz, denominator_approval_expires_at timestamptz, expected_entry_set_digest char(64), expected_source_set_digest char(64), expected_snapshot_digest char(64));
REVOKE ALL ON TYPE ops.funding_snapshot_import_v1 FROM PUBLIC;
CREATE TYPE ops.funding_snapshot_entry_input_v1 AS (ordinal integer, counterparty_group_id uuid, counterparty_group_digest char(64), grouping_state ops.funding_grouping_state, grouping_dispute_reason ops.funding_grouping_dispute_reason, grouping_evidence_digest char(64), member_supplier_ids uuid[], member_supplier_identity_digests char(64)[], funding_source_kind ops.funding_source_kind, government_related boolean, political_party_related boolean, procurement_supplier_related boolean, investigated_subject_related boolean, related_party boolean, related_case_ids uuid[], recognized_revenue_fact_ids uuid[], recognized_revenue_fact_digests char(64)[], recognized_revenue_fact_amounts numeric(24,6)[], binding_contract_period_ids uuid[], binding_contract_period_digests char(64)[], binding_contract_period_amounts numeric(24,6)[], external_funding_source_receipt_ids uuid[], external_funding_source_receipt_digests char(64)[], external_funding_source_signature_digests char(64)[], external_funding_source_kinds ops.funding_source_kind[], external_funding_amount_bases ops.funding_amount_basis[], external_funding_source_amounts numeric(24,6)[], expected_entry_source_set_digest char(64), expected_independent_review_requirement_digest char(64), expected_entry_digest char(64));
REVOKE ALL ON TYPE ops.funding_snapshot_entry_input_v1 FROM PUBLIC;
CREATE TYPE ops.funding_snapshot_import_receipt_v1 AS (receipt_id uuid, snapshot_header_id uuid, snapshot_batch_id uuid, snapshot_version bigint, snapshot_digest char(64), entry_count integer, entry_set_digest char(64), audit_event_id uuid, outbox_id uuid, response_digest char(64), receipt_digest char(64), committed_at timestamptz, idempotency_replay boolean);
REVOKE ALL ON TYPE ops.funding_snapshot_import_receipt_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_disclosure_publish_v1 AS (idempotency_key text, disclosure_id uuid, expected_prior_revision_id uuid, expected_prior_revision bigint, expected_prior_revision_digest char(64), fiscal_year integer, fiscal_quarter smallint, period_start date, period_end date, snapshot_header_id uuid, snapshot_batch_id uuid, snapshot_digest char(64), funding_policy_version text, funding_policy_digest char(64), naming_threshold_amount numeric(24,6), amount_band_lower numeric(24,6), amount_band_upper numeric(24,6), purpose text, conflict_summary text, policy_request_total integer, policy_request_accepted integer, policy_request_partially_accepted integer, policy_request_rejected integer, policy_request_withdrawn integer, policy_request_pending integer, expected_policy_request_outcome_digest char(64), expected_source_link_set_digest char(64), policy_snapshot_digest char(64), conflict_snapshot_id uuid, conflict_snapshot_digest char(64), proposal_id uuid, proposal_version bigint, execution_id uuid, execution_generation bigint, approval_digest char(64), execution_digest char(64), preparer_decision_id uuid, publisher_decision_id uuid, oversight_decision_id uuid, board_decision_id uuid, independent_case_review_decision_ids uuid[], prepared_by_user_id uuid, published_by_user_id uuid, oversight_reviewer_user_id uuid, board_approver_user_id uuid, effective_at timestamptz, expected_entry_set_digest char(64), expected_public_content_digest char(64), expected_revision_digest char(64));
REVOKE ALL ON TYPE editorial.funding_disclosure_publish_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_disclosure_entry_input_v1 AS (ordinal integer, source_snapshot_entry_ids uuid[], source_snapshot_entry_digests char(64)[], expected_source_snapshot_entry_set_digest char(64), identity_disclosure_mode editorial.funding_identity_disclosure_mode, public_display_name text, withholding_reason editorial.funding_identity_withholding_reason, withholding_public_explanation text, counterparty_category text, amount_band_lower numeric(24,6), amount_band_upper numeric(24,6), purpose text, conflict_disclosure text, mitigation_summary text, evidence_ids uuid[], expected_source_link_set_digest char(64), expected_entry_digest char(64));
REVOKE ALL ON TYPE editorial.funding_disclosure_entry_input_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_disclosure_publish_receipt_v1 AS (receipt_id uuid, revision_id uuid, disclosure_id uuid, revision bigint, revision_digest char(64), public_content_digest char(64), entry_count integer, entry_set_digest char(64), execution_receipt_id uuid, audit_event_id uuid, outbox_id uuid, response_digest char(64), receipt_digest char(64), committed_at timestamptz, idempotency_replay boolean);
REVOKE ALL ON TYPE editorial.funding_disclosure_publish_receipt_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_public_revision_v1 AS (disclosure_id uuid, revision bigint, prior_revision bigint, fiscal_year integer, fiscal_quarter smallint, period_start date, period_end date, reporting_currency char(3), concentration_band editorial.funding_concentration_band, unknown_reason editorial.funding_disclosure_unknown_reason, public_caveat_text text, purpose text, policy_request_total integer, policy_request_accepted integer, policy_request_partially_accepted integer, policy_request_rejected integer, policy_request_withdrawn integer, policy_request_pending integer, policy_request_outcome_digest char(64), source_link_set_digest char(64), entry_count integer, entry_set_digest char(64), funding_policy_version text, funding_policy_digest char(64), effective_at timestamptz, published_at timestamptz, public_content_digest char(64), revision_digest char(64), requires_enhanced_public_disclosure boolean);
REVOKE ALL ON TYPE editorial.funding_public_revision_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_public_entry_v1 AS (ordinal integer, identity_disclosure_mode editorial.funding_identity_disclosure_mode, public_display_name text, withholding_public_explanation text, counterparty_category text, funding_source_kind ops.funding_source_kind, amount_band_lower numeric(24,6), amount_band_upper numeric(24,6), reporting_currency char(3), concentration_band editorial.funding_concentration_band, denominator_unknown_reason ops.funding_denominator_unknown_reason, grouping_dispute_reason ops.funding_grouping_dispute_reason, concentration_unknown_reason ops.funding_concentration_unknown_reason, public_caveat_text text, purpose text, conflict_disclosure text, mitigation_summary text, government_related boolean, political_party_related boolean, procurement_supplier_related boolean, investigated_subject_related boolean, related_party boolean, public_case_refs text[], public_source_links text[], entry_digest char(64));
REVOKE ALL ON TYPE editorial.funding_public_entry_v1 FROM PUBLIC;
CREATE TYPE editorial.funding_public_projection_input_v1 AS (revision editorial.funding_public_revision_v1, entries editorial.funding_public_entry_v1[]);
REVOKE ALL ON TYPE editorial.funding_public_projection_input_v1 FROM PUBLIC;
CREATE TYPE ops.invoice_membership_read_row_v1 AS (usage_root_fact_id uuid, usage_fact_id uuid, usage_fact_digest char(64), meter_kind ops.usage_meter_kind, period_start date, period_end date, measurement_state ops.usage_measurement_state, membership_kind ops.invoice_usage_membership_kind, current_invoice_id uuid, current_membership_digest char(64), blocker_code text);
REVOKE ALL ON TYPE ops.invoice_membership_read_row_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.invoice_membership_read_row_v1 TO gurine_workflow_worker;
GRANT USAGE ON TYPE ops.invoice_membership_read_row_v1 TO gurine_control_api;
GRANT USAGE ON TYPE ops.invoice_membership_read_row_v1 TO gurine_auditor;
CREATE TYPE ops.offer_profile_capability_input_v1 AS (capability_ordinal smallint, capability_code ops.offer_capability_code, offer_state ops.offer_capability_state, quota_kind ops.offer_quota_kind, included_quantity numeric(24,6), overage_policy ops.offer_overage_policy, overage_unit_price numeric(24,6), activation_policy_digest char(64), consent_policy_digest char(64), cost_policy_digest char(64), entry_payload jsonb, entry_canonical bytea, entry_digest_preimage_canonical bytea);
REVOKE ALL ON TYPE ops.offer_profile_capability_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.offer_profile_capability_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.paid_evidence_packet_member_input_v1 AS (member_ordinal smallint, category ops.paid_evidence_member_category, source_set_id uuid, source_set_version bigint, source_set_digest char(64), disposition_kind text, member_payload jsonb, member_canonical bytea, member_digest_preimage_canonical bytea);
REVOKE ALL ON TYPE ops.paid_evidence_packet_member_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_evidence_packet_member_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.paid_evidence_packet_subject_input_v1 AS (source_event_id uuid, source_event_envelope_digest char(64), packet_id uuid, deployment_id uuid, organization_id uuid, sku ops.commercial_sku, qualification_receipt_id uuid, qualification_episode_id uuid, qualification_episode_version bigint, qualification_episode_digest char(64), commercial_contract_id uuid, commercial_contract_version bigint, commercial_contract_digest char(64), review_snapshot_id uuid, review_snapshot_version bigint, review_snapshot_digest char(64), paid_member_manifest_digest char(64), subject_binding_payload jsonb, subject_binding_canonical bytea, ordered_members ops.paid_evidence_packet_member_input_v1[], expected_packet_subject_digest char(64));
REVOKE ALL ON TYPE ops.paid_evidence_packet_subject_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_evidence_packet_subject_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.paid_terminal_binding_input_v1 AS (binding_source_event_id uuid, binding_source_event_envelope_digest char(64), logical_consumer text, packet_id uuid, expected_packet_version bigint, expected_packet_record_digest char(64), terminal_receipt_kind ops.paid_terminal_receipt_kind, terminal_receipt_id uuid, terminal_receipt_version bigint, terminal_receipt_digest char(64));
REVOKE ALL ON TYPE ops.paid_terminal_binding_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.paid_terminal_binding_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.sla_metric_input_v1 AS (organization_id uuid, contract_period_id uuid, sla_policy_version text, sla_policy_digest char(64), capability_set_digest char(64), exclusion_schedule_digest char(64), service_credit_schedule_digest char(64), sli_window_receipt_id uuid, sli_receipt_digest char(64), evaluation_state text);
REVOKE ALL ON TYPE ops.sla_metric_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.sla_metric_input_v1 TO gurine_workflow_worker;
GRANT USAGE ON TYPE ops.sla_metric_input_v1 TO gurine_control_api;
GRANT USAGE ON TYPE ops.sla_metric_input_v1 TO gurine_auditor;
CREATE TYPE ops.economics_mutation_receipt_v1 AS (receipt_id uuid, resource_type text, resource_id uuid, resource_version bigint, resource_digest char(64), audit_event_id uuid, outbox_id uuid, response_status integer, response_media_type text, response_body_bytes bytea, response_digest char(64), receipt_digest char(64), committed_at timestamptz, idempotency_replay boolean);
REVOKE ALL ON TYPE ops.economics_mutation_receipt_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.economics_mutation_receipt_v1 TO gurine_workflow_worker;
CREATE TYPE ops.usage_window_receipt_input_v1 AS (root_receipt_id uuid, receipt_version bigint, receipt_effect ops.usage_receipt_effect, supersedes_receipt_id uuid, predecessor_receipt_digest char(64), deployment_id uuid, organization_id uuid, contract_period_id uuid, contract_id uuid, tariff_version_id uuid, sku ops.commercial_sku, accounting_timezone text, accounting_policy_digest char(64), period_start date, period_end date, measurement_window_digest char(64), receipt_kind ops.usage_receipt_kind, meter_kind ops.usage_meter_kind, unit ops.usage_unit, measurement_state ops.usage_measurement_state, expected_item_count bigint, observed_item_count bigint, observed_quantity numeric(24,6), normalization_basis_kind ops.usage_normalization_basis_kind, normalization_input_quantity numeric(24,6), coverage_digest char(64), source_system_id text, source_window_identity_hmac char(64), source_window_hmac_key_version text, source_cursor_set_digest char(64), source_record_set_digest char(64), source_signature_digest char(64), meter_policy_version text, meter_policy_digest char(64), measured_at timestamptz, receipt_digest char(64));
REVOKE ALL ON TYPE ops.usage_window_receipt_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.usage_window_receipt_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.acquisition_source_receipt_input_v1 AS (root_receipt_id uuid, revision bigint, receipt_effect text, supersedes_receipt_id uuid, predecessor_receipt_digest char(64), deployment_id uuid, organization_id uuid, source_kind text, source_system_id text, source_record_identity_hmac char(64), source_record_hmac_key_version text, acquisition_campaign_digest char(64), organization_binding_digest char(64), attribution_model_version text, attribution_model_digest char(64), touchpoint_set_digest char(64), source_record_digest char(64), source_signature_digest char(64), valid_from timestamptz, valid_until timestamptz, attributed_at timestamptz, receipt_digest char(64));
REVOKE ALL ON TYPE ops.acquisition_source_receipt_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.acquisition_source_receipt_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.invoice_usage_membership_input_v1 AS (root_membership_id uuid, revision bigint, membership_effect ops.invoice_usage_membership_effect, supersedes_membership_id uuid, predecessor_invoice_id uuid, predecessor_membership_digest char(64), invoice_id uuid, deployment_id uuid, organization_id uuid, contract_period_id uuid, contract_id uuid, sku ops.commercial_sku, accounting_timezone text, currency char(3), usage_root_fact_id uuid, usage_fact_id uuid, usage_fact_revision bigint, usage_fact_digest char(64), usage_window_receipt_id uuid, usage_window_receipt_version bigint, usage_window_receipt_digest char(64), meter_kind ops.usage_meter_kind, period_start date, period_end date, measurement_window_digest char(64), measurement_state ops.usage_measurement_state, membership_kind ops.invoice_usage_membership_kind, billable_quantity numeric(24,6), included_quantity numeric(24,6), charged_quantity numeric(24,6), billable_unit ops.billable_unit, invoice_line_id uuid, allocation_policy_digest char(64), membership_digest char(64));
REVOKE ALL ON TYPE ops.invoice_usage_membership_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.invoice_usage_membership_input_v1 TO gurine_workflow_worker;
CREATE TYPE ops.commercial_qualification_receipt_input_v1 AS (root_receipt_id uuid, revision bigint, receipt_effect ops.commercial_qualification_receipt_effect, supersedes_receipt_id uuid, predecessor_receipt_digest char(64), qualification_episode_id uuid, deployment_id uuid, organization_id uuid, sku ops.commercial_sku, decision_effective_at timestamptz, first_qualified_at timestamptz, recurring_job_attested boolean, authorized_data_identified boolean, authorized_data_feasible boolean, economic_buyer_role_bound boolean, operational_owner_role_bound boolean, independent_reviewer_role_bound boolean, source_rights_owner_role_bound boolean, incident_support_owner_role_bound boolean, pilot_scope_accepted boolean, success_metric_accepted boolean, budget_authority_accepted boolean, support_expectation_accepted boolean, trust_terms_accepted boolean, role_binding_hmac_key_version text, economic_buyer_primary_role_binding_hmac char(64), economic_buyer_backup_role_binding_hmac char(64), operational_owner_primary_role_binding_hmac char(64), operational_owner_backup_role_binding_hmac char(64), independent_reviewer_primary_role_binding_hmac char(64), independent_reviewer_backup_role_binding_hmac char(64), source_rights_owner_primary_role_binding_hmac char(64), source_rights_owner_backup_role_binding_hmac char(64), incident_support_owner_primary_role_binding_hmac char(64), incident_support_owner_backup_role_binding_hmac char(64), source_system_id text, source_record_identity_hmac char(64), acquisition_source_receipt_id uuid, acquisition_source_receipt_digest char(64), source_signature_digest char(64), qualification_policy_version bigint, qualification_policy_digest char(64), criterion_set_digest char(64), role_binding_set_digest char(64), evidence_set_digest char(64), reason_code ops.commercial_qualification_reason, receipt_digest char(64));
REVOKE ALL ON TYPE ops.commercial_qualification_receipt_input_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.commercial_qualification_receipt_input_v1 TO gurine_workflow_worker;
CREATE OR REPLACE FUNCTION ops.round_half_even_numeric_v1(value numeric, scale integer)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
DECLARE factor numeric; magnitude numeric; whole numeric; fraction numeric; rounded numeric;
BEGIN
  IF scale < 0 OR scale > 12 THEN RAISE EXCEPTION 'round_half_even scale out of range' USING ERRCODE='22023'; END IF;
  factor := power(10::numeric, scale); magnitude := abs(value) * factor;
  whole := trunc(magnitude); fraction := magnitude - whole;
  rounded := CASE WHEN fraction < 0.5::numeric THEN whole
                  WHEN fraction > 0.5::numeric THEN whole + 1
                  WHEN mod(whole, 2) = 0 THEN whole ELSE whole + 1 END;
  RETURN sign(value) * rounded / factor;
END $$;
REVOKE ALL ON FUNCTION ops.round_half_even_numeric_v1(numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.round_half_even_numeric_v1(numeric, integer) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.offer_capability_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object'
    AND value ?& ARRAY['ordinal','capabilityCode','offerState','quotaKind','overagePolicy','entryDigest']
    AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(value) key
                    WHERE key NOT IN ('ordinal','capabilityCode','offerState','quotaKind','includedQuantity','overagePolicy','overageUnitPrice','activationPolicyDigest','consentPolicyDigest','costPolicyDigest','entryDigest'))
    AND value->>'entryDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_member_input_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['ordinal','category','memberSetDigest']
    AND value->>'memberSetDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_subject_binding_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','organizationId','subjectKind','orderedMemberBindings']
    AND jsonb_typeof(value->'orderedMemberBindings') = 'array';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_storage_record_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','packetVersion','state','packetDigest','packetRecordDigest']
    AND value->>'packetRecordDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','packetVersion','subjectKind','terminalReceipt']
    AND jsonb_typeof(value->'terminalReceipt') = 'object';
$$;
REVOKE ALL ON FUNCTION ops.offer_capability_v1_is_valid(jsonb), ops.paid_evidence_packet_member_input_v1_is_valid(jsonb), ops.paid_evidence_packet_subject_binding_v1_is_valid(jsonb), ops.paid_evidence_packet_storage_record_v1_is_valid(jsonb), ops.paid_evidence_packet_v1_is_valid(jsonb) FROM PUBLIC;

CREATE TABLE ops.fx_rate_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  root_rate_id uuid NOT NULL,
  revision bigint NOT NULL,
  fact_kind ops.fx_fact_kind NOT NULL,
  supersedes_rate_id uuid,
  source_currency char(3) NOT NULL,
  target_currency char(3) NOT NULL,
  quote_convention text NOT NULL,
  rate numeric(30,12),
  rate_kind ops.fx_rate_kind NOT NULL,
  source_id text NOT NULL,
  source_record_identity_hmac char(64) NOT NULL,
  source_record_hmac_key_version text NOT NULL,
  source_priority smallint NOT NULL,
  observed_at timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  rate_policy_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  correction_reason ops.fx_correction_reason,
  approver_id uuid,
  decision_digest char(64),
  sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_fx_rate_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.fx_rate_facts OWNER TO gurine_migrator;
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_root_revision_uq UNIQUE (root_rate_id, revision);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_source_record_revision_uq UNIQUE (deployment_id, source_id, source_record_identity_hmac, revision);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_sha_uq UNIQUE (sha256);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_revision_ck CHECK (revision > 0);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_currency_ck CHECK (source_currency ~ '^[A-Z]{3}$' AND target_currency ~ '^[A-Z]{3}$' AND source_currency <> target_currency);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_quote_convention_ck CHECK (quote_convention = 'TARGET_PER_SOURCE');
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_value_ck CHECK ((fact_kind IN ('OBSERVATION','REPLACEMENT') AND rate IS NOT NULL AND rate > 0) OR (fact_kind = 'WITHDRAWAL' AND rate IS NULL));
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_root_shape_ck CHECK ((fact_kind = 'OBSERVATION' AND revision = 1 AND root_rate_id = id AND supersedes_rate_id IS NULL AND correction_reason IS NULL AND approver_id IS NULL AND decision_digest IS NULL) OR (fact_kind IN ('REPLACEMENT','WITHDRAWAL') AND revision > 1 AND root_rate_id <> id AND supersedes_rate_id IS NOT NULL AND correction_reason IS NOT NULL AND approver_id IS NOT NULL AND decision_digest IS NOT NULL));
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_priority_ck CHECK (source_priority BETWEEN 0 AND 32767);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_interval_ck CHECK (observed_at < valid_until);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_hmac_key_version_ck CHECK (length(btrim(source_record_hmac_key_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_digest_ck CHECK (rate_policy_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND source_record_identity_hmac ~ '^[0-9a-f]{64}$' AND (decision_digest IS NULL OR decision_digest ~ '^[0-9a-f]{64}$') AND sha256 ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX fx_rate_one_successor_uq ON ops.fx_rate_facts USING btree (supersedes_rate_id) WHERE supersedes_rate_id IS NOT NULL;
CREATE INDEX fx_rate_selection_idx ON ops.fx_rate_facts USING btree (deployment_id, source_currency, target_currency, observed_at DESC, source_priority, revision DESC, id);
CREATE INDEX fx_rate_root_history_idx ON ops.fx_rate_facts USING btree (root_rate_id, revision, id);
CREATE INDEX fx_rate_source_fk_idx ON ops.fx_rate_facts USING btree (source_id, id);
CREATE INDEX fx_rate_approver_fk_idx ON ops.fx_rate_facts USING btree (approver_id, id) WHERE approver_id IS NOT NULL;
REVOKE ALL ON ops.fx_rate_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.fx_rate_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.fx_rate_facts TO gurine_control_api;
GRANT SELECT ON ops.fx_rate_facts TO gurine_auditor;
CREATE TABLE ops.product_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  emission_id uuid NOT NULL,
  event_name text NOT NULL,
  sensitivity text NOT NULL,
  purpose_code text NOT NULL,
  event_catalog_digest char(64) NOT NULL,
  deployment_id uuid NOT NULL,
  workflow_instance_hmac char(64) NOT NULL,
  workflow_key_version bigint NOT NULL,
  workflow_started_at timestamptz NOT NULL,
  workflow_expires_at timestamptz NOT NULL,
  occurred_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  record_class text NOT NULL,
  schedule_revision bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  retention_deadline timestamptz NOT NULL,
  screen_id text NOT NULL,
  surface text NOT NULL,
  app_version text NOT NULL,
  specification_version text NOT NULL,
  viewport_class text,
  success boolean,
  error_code text,
  internal_object_type text,
  workflow_stage text,
  result_code text,
  duration_bucket text,
  role_category text,
  public_object_type text,
  public_object_id text,
  state text,
  result_count_bucket text,
  filter_category_count smallint,
  step_id text,
  event_digest char(64) NOT NULL,
  CONSTRAINT ops_product_events_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.product_events OWNER TO gurine_migrator;
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_emission_unique UNIQUE (deployment_id, emission_id);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_digest_unique UNIQUE (event_digest);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_catalog_digest_lower_hex CHECK (event_catalog_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_workflow_hmac_lower_hex CHECK (workflow_instance_hmac ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_schedule_digest_lower_hex CHECK (schedule_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_event_digest_lower_hex CHECK (event_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_event_name_shape CHECK (event_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$' AND length(event_name) <= 128);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_sensitivity_closed CHECK (sensitivity IN ('PUBLIC_PRODUCT','INTERNAL_OPERATIONAL','RESPONSE_SENSITIVE_MINIMAL'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_purpose_closed CHECK (purpose_code = 'TASK_PROGRESSION_QUALITY_RECOVERY');
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_surface_closed CHECK (surface IN ('public','internal','response'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_surface_sensitivity_match CHECK ((surface = 'public' AND sensitivity = 'PUBLIC_PRODUCT') OR (surface = 'internal' AND sensitivity = 'INTERNAL_OPERATIONAL') OR (surface = 'response' AND sensitivity = 'RESPONSE_SENSITIVE_MINIMAL'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_record_class_match CHECK ((sensitivity = 'PUBLIC_PRODUCT' AND record_class = 'PRODUCT_ANALYTICS_PUBLIC') OR (sensitivity = 'INTERNAL_OPERATIONAL' AND record_class = 'PRODUCT_ANALYTICS_INTERNAL') OR (sensitivity = 'RESPONSE_SENSITIVE_MINIMAL' AND record_class = 'PRODUCT_ANALYTICS_RESPONSE'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_schedule_revision_positive CHECK (schedule_revision > 0 AND workflow_key_version > 0);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_workflow_window CHECK (workflow_started_at <= occurred_at AND occurred_at < workflow_expires_at AND ((surface IN ('public','response') AND workflow_expires_at <= workflow_started_at + interval '24 hours') OR (surface = 'internal' AND workflow_expires_at <= workflow_started_at + interval '30 days')));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_retention_deadline_after_record CHECK (retention_deadline > recorded_at);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_retention_hard_cap CHECK ((sensitivity = 'RESPONSE_SENSITIVE_MINIMAL' AND retention_deadline <= recorded_at + interval '30 days') OR (sensitivity IN ('PUBLIC_PRODUCT','INTERNAL_OPERATIONAL') AND retention_deadline <= recorded_at + interval '90 days'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_screen_id_bounded CHECK (screen_id ~ '^[A-Z]{3,4}-[0-9]{3}$' AND length(screen_id) <= 8);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_version_strings_bounded CHECK (length(app_version) BETWEEN 1 AND 64 AND length(specification_version) BETWEEN 1 AND 64);
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_code_properties_bounded CHECK ((error_code IS NULL OR (error_code ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (internal_object_type IS NULL OR (internal_object_type ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (workflow_stage IS NULL OR (workflow_stage ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (result_code IS NULL OR (result_code ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (duration_bucket IS NULL OR (duration_bucket ~ '^[A-Z0-9][A-Z0-9_]{0,31}$')) AND (role_category IS NULL OR (role_category ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (public_object_type IS NULL OR (public_object_type ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (state IS NULL OR (state ~ '^[A-Z][A-Z0-9_]{0,63}$')) AND (result_count_bucket IS NULL OR (result_count_bucket ~ '^[A-Z0-9][A-Z0-9_]{0,31}$')) AND (step_id IS NULL OR (step_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')) AND (viewport_class IS NULL OR viewport_class IN ('COMPACT','MEDIUM','WIDE','NON_VISUAL')));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_public_object_id_bounded CHECK (public_object_id IS NULL OR (length(public_object_id) BETWEEN 1 AND 128 AND public_object_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_public_object_pair CHECK ((public_object_type IS NULL) = (public_object_id IS NULL));
ALTER TABLE ops.product_events ADD CONSTRAINT product_events_filter_count_bounded CHECK (filter_category_count IS NULL OR filter_category_count BETWEEN 0 AND 64);
CREATE INDEX product_events_name_time_idx ON ops.product_events USING btree (event_name, occurred_at DESC, id DESC) INCLUDE (screen_id, success, result_code);
CREATE INDEX product_events_screen_time_idx ON ops.product_events USING btree (screen_id, occurred_at DESC, id DESC) INCLUDE (event_name, surface);
CREATE INDEX product_events_retention_idx ON ops.product_events USING btree (record_class, retention_deadline, id) INCLUDE (event_digest);
CREATE INDEX product_events_workflow_idx ON ops.product_events USING btree (workflow_instance_hmac, occurred_at, id) INCLUDE (event_name, screen_id, event_digest);
CREATE INDEX product_events_public_object_idx ON ops.product_events USING btree (public_object_type, public_object_id, occurred_at DESC, id DESC) INCLUDE (event_name) WHERE public_object_id IS NOT NULL;
REVOKE ALL ON ops.product_events FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.product_events TO gurine_workflow_worker;
CREATE TABLE ops.outcome_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  fact_contract_version smallint NOT NULL DEFAULT 1,
  root_fact_id uuid NOT NULL,
  supersedes_fact_id uuid,
  correction_sequence bigint NOT NULL DEFAULT 1,
  fact_effect text NOT NULL DEFAULT 'ORIGINAL'::text,
  fact_type text NOT NULL,
  scope_kind text NOT NULL,
  deployment_id uuid NOT NULL,
  metric_timezone text NOT NULL,
  metric_policy_digest char(64) NOT NULL,
  workflow_instance_hmac char(64) NOT NULL,
  workflow_key_version bigint NOT NULL,
  workflow_proof jsonb NOT NULL,
  workflow_proof_digest char(64) NOT NULL,
  milestone_set_digest char(64) NOT NULL,
  workflow_completed_at timestamptz NOT NULL,
  organization_id uuid,
  subject_scope_digest char(64) NOT NULL,
  subject_scope_key_version bigint NOT NULL,
  terminal_receipt_kind text NOT NULL,
  terminal_receipt_id uuid NOT NULL,
  terminal_receipt_version bigint NOT NULL,
  terminal_receipt_digest char(64) NOT NULL,
  paid_packet_id uuid,
  paid_packet_version bigint,
  paid_packet_digest char(64),
  paid_subject_kind ops.paid_evidence_subject_kind,
  paid_terminal_receipt_kind ops.paid_terminal_receipt_kind,
  paid_terminal_resulting_state ops.paid_terminal_resulting_state,
  effective_from timestamptz NOT NULL,
  effective_until timestamptz,
  formula_version bigint NOT NULL,
  formula_digest char(64) NOT NULL,
  correction_reason_code text,
  correction_decision_digest char(64),
  correction_receipt_id uuid,
  correction_receipt_digest char(64),
  record_class text NOT NULL DEFAULT 'PRODUCT_OUTCOME_FACT'::text,
  schedule_revision bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  fact_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_outcome_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.outcome_facts OWNER TO gurine_migrator;
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_digest_unique UNIQUE (fact_digest);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_root_sequence_unique UNIQUE (root_fact_id, correction_sequence);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_invalidation_binding_unique UNIQUE (id, correction_sequence, fact_digest);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_paid_binding_unique UNIQUE (id, fact_digest, organization_id, paid_subject_kind, terminal_receipt_id, terminal_receipt_version, terminal_receipt_digest, paid_terminal_receipt_kind, paid_terminal_resulting_state, effective_from, paid_packet_id, paid_packet_version, paid_packet_digest);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_subject_scope_digest_lower_hex CHECK (subject_scope_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_metric_policy_digest_lower_hex CHECK (metric_policy_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_workflow_digests_lower_hex CHECK (workflow_instance_hmac ~ '^[0-9a-f]{64}$' AND workflow_proof_digest ~ '^[0-9a-f]{64}$' AND milestone_set_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_terminal_receipt_digest_lower_hex CHECK (terminal_receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_paid_packet_digest_lower_hex CHECK (paid_packet_digest IS NULL OR paid_packet_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_formula_digest_lower_hex CHECK (formula_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_correction_decision_digest_lower_hex CHECK (correction_decision_digest IS NULL OR correction_decision_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_correction_receipt_digest_lower_hex CHECK (correction_receipt_digest IS NULL OR correction_receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_schedule_digest_lower_hex CHECK (schedule_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_fact_digest_lower_hex CHECK (fact_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_sequence_positive CHECK (correction_sequence > 0);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_contract_version_shape CHECK ((fact_contract_version = 1 AND num_nonnulls(paid_packet_id,paid_packet_version,paid_packet_digest,paid_subject_kind,paid_terminal_receipt_kind,paid_terminal_resulting_state) = 0) OR (fact_contract_version = 2 AND num_nonnulls(paid_packet_id,paid_packet_version,paid_packet_digest,paid_subject_kind,paid_terminal_receipt_kind,paid_terminal_resulting_state) = 6));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_versions_positive CHECK (workflow_key_version > 0 AND subject_scope_key_version > 0 AND terminal_receipt_version > 0 AND formula_version > 0 AND schedule_revision > 0);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_workflow_proof_object CHECK (jsonb_typeof(workflow_proof) = 'object');
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_workflow_completion_time CHECK (workflow_completed_at = effective_from);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_effect_closed CHECK (fact_effect IN ('ORIGINAL','INVERSE','SUPERSEDING'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_type_closed CHECK (fact_type IN ('TRIAGED_SIGNAL','REVIEWED_INVESTIGATION','ACCEPTED_PROPOSAL','AUDITED_DELIVERY','COMPLETED_DECISION_CYCLE','PUBLICATION','CORRECTION'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_scope_closed CHECK (scope_kind IN ('PUBLIC','ORGANIZATION'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_scope_identity CHECK ((scope_kind = 'PUBLIC' AND organization_id IS NULL) OR (scope_kind = 'ORGANIZATION' AND organization_id IS NOT NULL));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_metric_timezone_shape CHECK (length(metric_timezone) BETWEEN 1 AND 64 AND (metric_timezone = 'UTC' OR metric_timezone ~ '^[A-Za-z][A-Za-z0-9._+-]*/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_receipt_kind_closed CHECK (terminal_receipt_kind IN ('SIGNAL_TRIAGE','REVIEW_DECISION','EXECUTION','OUTBOUND_DELIVERY','ORGANIZATION_DECISION','PUBLICATION','CORRECTION'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_type_receipt_match CHECK ((fact_type = 'TRIAGED_SIGNAL' AND terminal_receipt_kind = 'SIGNAL_TRIAGE') OR (fact_type = 'REVIEWED_INVESTIGATION' AND terminal_receipt_kind = 'REVIEW_DECISION') OR (fact_type = 'ACCEPTED_PROPOSAL' AND terminal_receipt_kind = 'EXECUTION') OR (fact_type = 'AUDITED_DELIVERY' AND terminal_receipt_kind = 'OUTBOUND_DELIVERY') OR (fact_type = 'COMPLETED_DECISION_CYCLE' AND terminal_receipt_kind = 'ORGANIZATION_DECISION') OR (fact_type = 'PUBLICATION' AND terminal_receipt_kind = 'PUBLICATION') OR (fact_type = 'CORRECTION' AND terminal_receipt_kind = 'CORRECTION'));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_paid_packet_shape CHECK (fact_contract_version = 1 OR (paid_packet_version = 2 AND scope_kind = 'ORGANIZATION' AND organization_id IS NOT NULL AND paid_subject_kind::text = fact_type AND paid_terminal_receipt_kind::text = terminal_receipt_kind AND ((paid_subject_kind = 'AUDITED_DELIVERY' AND paid_terminal_receipt_kind = 'OUTBOUND_DELIVERY' AND paid_terminal_resulting_state IN ('DELIVERED','READ')) OR (paid_subject_kind = 'COMPLETED_DECISION_CYCLE' AND paid_terminal_receipt_kind = 'ORGANIZATION_DECISION' AND paid_terminal_resulting_state IN ('REJECTED_FINAL','EFFECT_SUCCEEDED')))));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_effective_interval CHECK (effective_until IS NULL OR effective_until > effective_from);
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_correction_shape CHECK ((fact_effect = 'ORIGINAL' AND root_fact_id = id AND supersedes_fact_id IS NULL AND correction_sequence = 1 AND correction_reason_code IS NULL AND correction_decision_digest IS NULL AND correction_receipt_id IS NULL AND correction_receipt_digest IS NULL) OR (fact_effect IN ('INVERSE','SUPERSEDING') AND root_fact_id <> id AND supersedes_fact_id IS NOT NULL AND correction_sequence > 1 AND correction_reason_code IS NOT NULL AND correction_reason_code ~ '^[A-Z][A-Z0-9_]{0,63}$' AND correction_decision_digest IS NOT NULL AND correction_receipt_id IS NOT NULL AND correction_receipt_digest IS NOT NULL));
ALTER TABLE ops.outcome_facts ADD CONSTRAINT outcome_facts_record_class_fixed CHECK (record_class = 'PRODUCT_OUTCOME_FACT');
CREATE UNIQUE INDEX outcome_facts_supersedes_unique ON ops.outcome_facts USING btree (supersedes_fact_id) WHERE supersedes_fact_id IS NOT NULL;
CREATE UNIQUE INDEX outcome_facts_original_receipt_unique ON ops.outcome_facts USING btree (deployment_id, terminal_receipt_kind, terminal_receipt_id, formula_version) WHERE fact_effect = 'ORIGINAL';
CREATE UNIQUE INDEX outcome_facts_original_workflow_unique ON ops.outcome_facts USING btree (deployment_id, workflow_instance_hmac, formula_version) WHERE fact_effect = 'ORIGINAL';
CREATE INDEX outcome_facts_window_idx ON ops.outcome_facts USING btree (deployment_id, scope_kind, organization_id, fact_type, effective_from, id) INCLUDE (effective_until, root_fact_id, correction_sequence, fact_effect, fact_digest);
CREATE INDEX outcome_facts_workflow_idx ON ops.outcome_facts USING btree (workflow_instance_hmac, correction_sequence DESC, id) INCLUDE (workflow_proof_digest, milestone_set_digest, fact_effect, fact_digest);
CREATE INDEX outcome_facts_chain_idx ON ops.outcome_facts USING btree (root_fact_id, correction_sequence DESC, id DESC) INCLUDE (fact_effect, fact_type, effective_from, effective_until, fact_digest);
CREATE INDEX outcome_facts_terminal_receipt_idx ON ops.outcome_facts USING btree (terminal_receipt_kind, terminal_receipt_id, terminal_receipt_version) INCLUDE (terminal_receipt_digest, fact_digest);
CREATE INDEX outcome_facts_metric_idx ON ops.outcome_facts USING btree (fact_type, effective_from, id) INCLUDE (deployment_id, scope_kind, organization_id, root_fact_id, correction_sequence);
REVOKE ALL ON ops.outcome_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.outcome_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.outcome_facts TO gurine_control_api;
GRANT SELECT ON ops.outcome_facts TO gurine_auditor;
CREATE TABLE ops.acquisition_source_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_receipt_id uuid NOT NULL,
  revision bigint NOT NULL,
  receipt_effect text NOT NULL,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  source_kind text NOT NULL,
  source_system_id text NOT NULL,
  source_record_identity_hmac char(64) NOT NULL,
  source_record_hmac_key_version text NOT NULL,
  acquisition_campaign_digest char(64) NOT NULL,
  organization_binding_digest char(64) NOT NULL,
  attribution_model_version text NOT NULL,
  attribution_model_digest char(64) NOT NULL,
  touchpoint_set_digest char(64) NOT NULL,
  source_record_digest char(64) NOT NULL,
  source_signature_digest char(64) NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  attributed_at timestamptz NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_acquisition_source_receipts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.acquisition_source_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_root_revision_uq UNIQUE (root_receipt_id, revision);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_source_revision_uq UNIQUE (deployment_id, source_system_id, source_record_identity_hmac, revision);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_reference_uq UNIQUE (id, receipt_digest);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_revision_ck CHECK (revision > 0);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_chain_ck CHECK ((receipt_effect = 'ORIGINAL' AND revision = 1 AND root_receipt_id = id AND supersedes_receipt_id IS NULL AND predecessor_receipt_digest IS NULL) OR (receipt_effect IN ('REPLACEMENT','REVERSAL') AND revision > 1 AND root_receipt_id <> id AND supersedes_receipt_id IS NOT NULL AND predecessor_receipt_digest IS NOT NULL));
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_effect_ck CHECK (receipt_effect IN ('ORIGINAL','REPLACEMENT','REVERSAL'));
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_source_kind_ck CHECK (source_kind IN ('ORGANIC_SEARCH','REFERRAL','DIRECT','PARTNER','EVENT','PAID_SEARCH','PAID_SOCIAL','CONTENT','OUTBOUND','OTHER_REVIEWED'));
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_source_ck CHECK (source_system_id ~ '^[a-z0-9][a-z0-9._-]{0,127}$' AND length(btrim(source_record_hmac_key_version)) BETWEEN 1 AND 100 AND length(btrim(attribution_model_version)) BETWEEN 1 AND 128);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_interval_ck CHECK (valid_from < valid_until AND valid_from <= attributed_at AND attributed_at < valid_until AND attributed_at <= created_at);
ALTER TABLE ops.acquisition_source_receipts ADD CONSTRAINT acquisition_source_receipt_digest_ck CHECK ((predecessor_receipt_digest IS NULL OR predecessor_receipt_digest ~ '^[0-9a-f]{64}$') AND source_record_identity_hmac ~ '^[0-9a-f]{64}$' AND acquisition_campaign_digest ~ '^[0-9a-f]{64}$' AND organization_binding_digest ~ '^[0-9a-f]{64}$' AND attribution_model_digest ~ '^[0-9a-f]{64}$' AND touchpoint_set_digest ~ '^[0-9a-f]{64}$' AND source_record_digest ~ '^[0-9a-f]{64}$' AND source_signature_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX acquisition_source_receipt_one_successor_uq ON ops.acquisition_source_receipts USING btree (supersedes_receipt_id) WHERE supersedes_receipt_id IS NOT NULL;
CREATE INDEX acquisition_source_receipt_root_history_idx ON ops.acquisition_source_receipts USING btree (root_receipt_id, revision, id) INCLUDE (receipt_effect, receipt_digest);
CREATE INDEX acquisition_source_receipt_org_campaign_idx ON ops.acquisition_source_receipts USING btree (deployment_id, organization_id, acquisition_campaign_digest, attributed_at DESC, id) INCLUDE (source_kind, receipt_digest);
CREATE INDEX acquisition_source_receipt_source_idx ON ops.acquisition_source_receipts USING btree (source_system_id, source_record_identity_hmac, revision, id) INCLUDE (receipt_digest);
REVOKE ALL ON ops.acquisition_source_receipts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.acquisition_source_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.acquisition_source_receipts TO gurine_control_api;
GRANT SELECT ON ops.acquisition_source_receipts TO gurine_auditor;
CREATE TABLE ops.cost_allocations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  row_kind text NOT NULL,
  period_revision_id uuid NOT NULL,
  period_revision_row_kind text NOT NULL DEFAULT 'PERIOD'::text,
  supersedes_period_revision_id uuid,
  supersedes_period_row_kind text,
  deployment_id uuid NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  currency char(3) NOT NULL,
  period_version bigint NOT NULL DEFAULT 1,
  line_sequence bigint NOT NULL,
  source_set_digest char(64),
  pool_set_digest char(64),
  driver_set_digest char(64),
  correction_set_digest char(64),
  allocation_set_digest char(64),
  captured_cost_count bigint,
  expected_cost_count bigint,
  cost_capture_state text,
  cost_capture_coverage numeric(18,12),
  direct_eligible_amount numeric(24,6),
  direct_allocated_amount numeric(24,6),
  captured_cost_amount numeric(24,6),
  attributed_cost_amount numeric(24,6),
  unallocated_amount numeric(24,6),
  direct_coverage numeric(18,12),
  total_coverage numeric(18,12),
  claim_state text,
  incomplete_reason_set_digest char(64),
  unknown_cost_scope_digest char(64),
  close_receipt_id uuid,
  close_receipt_digest char(64),
  closed_at timestamptz,
  allocation_kind text,
  cost_category text,
  source_cost_event_id uuid,
  source_effective_digest char(64),
  source_currency char(3),
  source_amount numeric(24,6),
  fx_rate_fact_id uuid,
  reporting_source_amount numeric(24,6),
  target_kind text,
  job_id uuid,
  agent_run_id uuid,
  case_id uuid,
  organization_id uuid,
  outcome_fact_id uuid,
  acquisition_campaign_digest char(64),
  acquisition_source_receipt_id uuid,
  acquisition_source_receipt_digest char(64),
  acquisition_attribution_state ops.acquisition_attribution_state,
  unattributed_acquisition_pool_digest char(64),
  driver_kind text,
  driver_quantity numeric(24,6),
  driver_total_quantity numeric(24,6),
  allocation_ratio numeric(18,12),
  rounding_adjustment numeric(24,6),
  allocated_amount numeric(24,6),
  allocation_rule_version bigint,
  allocation_rule_digest char(64),
  record_class text NOT NULL DEFAULT 'COMMERCIAL_ACCOUNTING_FACT'::text,
  schedule_revision bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_cost_allocations_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.cost_allocations OWNER TO gurine_migrator;
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_record_digest_unique UNIQUE (record_digest);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_id_kind_unique UNIQUE (id, row_kind);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_period_line_unique UNIQUE (deployment_id, period_start, period_end, currency, period_version, line_sequence);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_currency_shape CHECK (currency ~ '^[A-Z]{3}$' AND (source_currency IS NULL OR source_currency ~ '^[A-Z]{3}$'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_period_interval CHECK (period_end > period_start);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_version_positive CHECK (period_version > 0 AND schedule_revision > 0);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_sequence_nonnegative CHECK (line_sequence >= 0);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_row_kind_closed CHECK (row_kind IN ('PERIOD','LINE'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_period_reference_kind CHECK (period_revision_row_kind = 'PERIOD' AND ((supersedes_period_revision_id IS NULL AND supersedes_period_row_kind IS NULL) OR (supersedes_period_revision_id IS NOT NULL AND supersedes_period_row_kind = 'PERIOD')));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_digest_lower_hex CHECK (accounting_policy_digest ~ '^[0-9a-f]{64}$' AND (source_set_digest IS NULL OR source_set_digest ~ '^[0-9a-f]{64}$') AND (pool_set_digest IS NULL OR pool_set_digest ~ '^[0-9a-f]{64}$') AND (driver_set_digest IS NULL OR driver_set_digest ~ '^[0-9a-f]{64}$') AND (correction_set_digest IS NULL OR correction_set_digest ~ '^[0-9a-f]{64}$') AND (allocation_set_digest IS NULL OR allocation_set_digest ~ '^[0-9a-f]{64}$') AND (incomplete_reason_set_digest IS NULL OR incomplete_reason_set_digest ~ '^[0-9a-f]{64}$') AND (unknown_cost_scope_digest IS NULL OR unknown_cost_scope_digest ~ '^[0-9a-f]{64}$') AND (close_receipt_digest IS NULL OR close_receipt_digest ~ '^[0-9a-f]{64}$') AND (source_effective_digest IS NULL OR source_effective_digest ~ '^[0-9a-f]{64}$') AND (acquisition_campaign_digest IS NULL OR acquisition_campaign_digest ~ '^[0-9a-f]{64}$') AND (acquisition_source_receipt_digest IS NULL OR acquisition_source_receipt_digest ~ '^[0-9a-f]{64}$') AND (unattributed_acquisition_pool_digest IS NULL OR unattributed_acquisition_pool_digest ~ '^[0-9a-f]{64}$') AND (allocation_rule_digest IS NULL OR allocation_rule_digest ~ '^[0-9a-f]{64}$') AND schedule_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_accounting_timezone_shape CHECK (length(accounting_timezone) BETWEEN 1 AND 64 AND (accounting_timezone = 'UTC' OR accounting_timezone ~ '^[A-Za-z][A-Za-z0-9._+-]*/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_period_revision_shape CHECK ((row_kind = 'PERIOD' AND period_revision_id = id AND line_sequence = 0 AND ((period_version = 1 AND supersedes_period_revision_id IS NULL) OR (period_version > 1 AND supersedes_period_revision_id IS NOT NULL))) OR (row_kind = 'LINE' AND period_revision_id <> id AND supersedes_period_revision_id IS NULL AND line_sequence > 0));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_period_header_shape CHECK (row_kind <> 'PERIOD' OR (source_set_digest IS NOT NULL AND pool_set_digest IS NOT NULL AND driver_set_digest IS NOT NULL AND correction_set_digest IS NOT NULL AND allocation_set_digest IS NOT NULL AND captured_cost_count IS NOT NULL AND captured_cost_count >= 0 AND cost_capture_state IS NOT NULL AND direct_eligible_amount IS NOT NULL AND direct_allocated_amount IS NOT NULL AND captured_cost_amount IS NOT NULL AND attributed_cost_amount IS NOT NULL AND unallocated_amount IS NOT NULL AND direct_coverage IS NOT NULL AND total_coverage IS NOT NULL AND claim_state IS NOT NULL AND close_receipt_id IS NOT NULL AND close_receipt_digest IS NOT NULL AND closed_at IS NOT NULL AND allocation_kind IS NULL AND cost_category IS NULL AND source_cost_event_id IS NULL AND source_effective_digest IS NULL AND source_currency IS NULL AND source_amount IS NULL AND fx_rate_fact_id IS NULL AND reporting_source_amount IS NULL AND target_kind IS NULL AND job_id IS NULL AND agent_run_id IS NULL AND case_id IS NULL AND organization_id IS NULL AND outcome_fact_id IS NULL AND acquisition_campaign_digest IS NULL AND acquisition_source_receipt_id IS NULL AND acquisition_source_receipt_digest IS NULL AND acquisition_attribution_state IS NULL AND unattributed_acquisition_pool_digest IS NULL AND driver_kind IS NULL AND driver_quantity IS NULL AND driver_total_quantity IS NULL AND allocation_ratio IS NULL AND rounding_adjustment IS NULL AND allocated_amount IS NULL AND allocation_rule_version IS NULL AND allocation_rule_digest IS NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_line_shape CHECK (row_kind <> 'LINE' OR (source_set_digest IS NULL AND pool_set_digest IS NULL AND driver_set_digest IS NULL AND correction_set_digest IS NULL AND allocation_set_digest IS NULL AND captured_cost_count IS NULL AND expected_cost_count IS NULL AND cost_capture_state IS NULL AND cost_capture_coverage IS NULL AND direct_eligible_amount IS NULL AND direct_allocated_amount IS NULL AND captured_cost_amount IS NULL AND attributed_cost_amount IS NULL AND unallocated_amount IS NULL AND direct_coverage IS NULL AND total_coverage IS NULL AND claim_state IS NULL AND incomplete_reason_set_digest IS NULL AND unknown_cost_scope_digest IS NULL AND close_receipt_id IS NULL AND close_receipt_digest IS NULL AND closed_at IS NULL AND allocation_kind IS NOT NULL AND cost_category IS NOT NULL AND source_cost_event_id IS NOT NULL AND source_effective_digest IS NOT NULL AND source_currency IS NOT NULL AND source_amount IS NOT NULL AND reporting_source_amount IS NOT NULL AND target_kind IS NOT NULL AND driver_kind IS NOT NULL AND rounding_adjustment IS NOT NULL AND allocated_amount IS NOT NULL AND allocation_rule_version IS NOT NULL AND allocation_rule_digest IS NOT NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_capture_state_closed CHECK (cost_capture_state IS NULL OR cost_capture_state IN ('MEASURED','UNKNOWN'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_capture_state_shape CHECK (row_kind <> 'PERIOD' OR (cost_capture_state = 'MEASURED' AND expected_cost_count IS NOT NULL AND expected_cost_count >= captured_cost_count AND cost_capture_coverage IS NOT NULL AND unknown_cost_scope_digest IS NULL) OR (cost_capture_state = 'UNKNOWN' AND expected_cost_count IS NULL AND cost_capture_coverage IS NULL AND unknown_cost_scope_digest IS NOT NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_capture_coverage_formula CHECK (row_kind <> 'PERIOD' OR cost_capture_state <> 'MEASURED' OR (cost_capture_coverage BETWEEN 0 AND 1 AND cost_capture_coverage = CASE WHEN expected_cost_count = 0 THEN 1::numeric ELSE ops.round_half_even_numeric_v1(captured_cost_count::numeric / expected_cost_count::numeric, 12) END));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_header_amounts CHECK (row_kind <> 'PERIOD' OR (direct_eligible_amount >= 0 AND direct_allocated_amount >= 0 AND direct_allocated_amount <= direct_eligible_amount AND captured_cost_amount >= 0 AND attributed_cost_amount >= 0 AND unallocated_amount >= 0 AND captured_cost_amount = attributed_cost_amount + unallocated_amount AND direct_coverage BETWEEN 0 AND 1 AND total_coverage BETWEEN 0 AND 1 AND direct_coverage = CASE WHEN direct_eligible_amount = 0 THEN 1::numeric ELSE ops.round_half_even_numeric_v1(direct_allocated_amount / direct_eligible_amount, 12) END AND total_coverage = CASE WHEN captured_cost_amount = 0 THEN 1::numeric ELSE ops.round_half_even_numeric_v1(attributed_cost_amount / captured_cost_amount, 12) END));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_claim_state_closed CHECK (claim_state IS NULL OR claim_state IN ('ELIGIBLE','INCOMPLETE','NO_ACTIVITY'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_claim_state_shape CHECK (row_kind <> 'PERIOD' OR (claim_state = 'NO_ACTIVITY' AND captured_cost_count = 0 AND expected_cost_count = 0 AND captured_cost_amount = 0 AND direct_eligible_amount = 0 AND cost_capture_state = 'MEASURED' AND cost_capture_coverage = 1 AND direct_coverage = 1 AND total_coverage = 1 AND incomplete_reason_set_digest IS NULL AND unknown_cost_scope_digest IS NULL) OR (claim_state = 'ELIGIBLE' AND captured_cost_amount > 0 AND cost_capture_state = 'MEASURED' AND cost_capture_coverage >= 0.99 AND direct_coverage = 1 AND total_coverage >= 0.95 AND incomplete_reason_set_digest IS NULL AND unknown_cost_scope_digest IS NULL) OR (claim_state = 'INCOMPLETE' AND incomplete_reason_set_digest IS NOT NULL AND (cost_capture_state = 'UNKNOWN' OR cost_capture_coverage < 0.99 OR direct_coverage < 1 OR total_coverage < 0.95)));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_allocation_kind_closed CHECK (allocation_kind IS NULL OR allocation_kind IN ('DIRECT','SHARED','UNALLOCATED'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_cost_category_closed CHECK (cost_category IS NULL OR cost_category IN ('COMPUTE','DATABASE_WAL_BACKUP','STORAGE','EGRESS','MODEL_OCR','SEARCH','DELIVERY','OBSERVABILITY','SUPPORT','HUMAN_REVIEW','LEGAL_SECURITY','SALES_CUSTOMER_ACQUISITION'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_target_kind_closed CHECK (target_kind IS NULL OR target_kind IN ('JOB','AGENT_RUN','CASE','ORGANIZATION','OUTCOME_FACT','UNALLOCATED'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_exact_target CHECK (row_kind <> 'LINE' OR (target_kind = 'JOB' AND job_id IS NOT NULL AND agent_run_id IS NULL AND case_id IS NULL AND organization_id IS NULL AND outcome_fact_id IS NULL) OR (target_kind = 'AGENT_RUN' AND job_id IS NULL AND agent_run_id IS NOT NULL AND case_id IS NULL AND organization_id IS NULL AND outcome_fact_id IS NULL) OR (target_kind = 'CASE' AND job_id IS NULL AND agent_run_id IS NULL AND case_id IS NOT NULL AND organization_id IS NULL AND outcome_fact_id IS NULL) OR (target_kind = 'ORGANIZATION' AND job_id IS NULL AND agent_run_id IS NULL AND case_id IS NULL AND organization_id IS NOT NULL AND outcome_fact_id IS NULL) OR (target_kind = 'OUTCOME_FACT' AND job_id IS NULL AND agent_run_id IS NULL AND case_id IS NULL AND organization_id IS NULL AND outcome_fact_id IS NOT NULL) OR (target_kind = 'UNALLOCATED' AND job_id IS NULL AND agent_run_id IS NULL AND case_id IS NULL AND organization_id IS NULL AND outcome_fact_id IS NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_acquisition_shape CHECK (row_kind <> 'LINE' OR (cost_category = 'SALES_CUSTOMER_ACQUISITION' AND acquisition_attribution_state = 'ATTRIBUTED' AND target_kind = 'ORGANIZATION' AND organization_id IS NOT NULL AND acquisition_campaign_digest IS NOT NULL AND acquisition_source_receipt_id IS NOT NULL AND acquisition_source_receipt_digest IS NOT NULL AND unattributed_acquisition_pool_digest IS NULL) OR (cost_category = 'SALES_CUSTOMER_ACQUISITION' AND acquisition_attribution_state = 'UNATTRIBUTED' AND allocation_kind = 'UNALLOCATED' AND target_kind = 'UNALLOCATED' AND organization_id IS NULL AND acquisition_source_receipt_id IS NULL AND acquisition_source_receipt_digest IS NULL AND unattributed_acquisition_pool_digest IS NOT NULL) OR (cost_category <> 'SALES_CUSTOMER_ACQUISITION' AND acquisition_campaign_digest IS NULL AND acquisition_source_receipt_id IS NULL AND acquisition_source_receipt_digest IS NULL AND acquisition_attribution_state IS NULL AND unattributed_acquisition_pool_digest IS NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_driver_kind_closed CHECK (driver_kind IS NULL OR driver_kind IN ('DIRECT_IDENTITY','RAW_RECORD','NORMALIZED_LINE','OCR_PAGE','ANALYSIS_JOB','COHORT_RERUN','EVIDENCE_PACKET','API_RECORD_UNIT','GB_MONTH','DELIVERY_ATTEMPT_1000','SUPPORT_HOUR','MATERIAL_CORRECTION_HOUR','NONE'));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_driver_shape CHECK (row_kind <> 'LINE' OR (allocation_kind = 'DIRECT' AND target_kind <> 'UNALLOCATED' AND driver_kind = 'DIRECT_IDENTITY' AND driver_quantity IS NULL AND driver_total_quantity IS NULL AND allocation_ratio IS NULL AND rounding_adjustment = 0 AND allocated_amount = reporting_source_amount) OR (allocation_kind = 'SHARED' AND target_kind <> 'UNALLOCATED' AND driver_kind NOT IN ('DIRECT_IDENTITY','NONE') AND driver_quantity IS NOT NULL AND driver_total_quantity IS NOT NULL AND allocation_ratio IS NOT NULL AND driver_quantity > 0 AND driver_total_quantity >= driver_quantity AND allocation_ratio > 0 AND allocation_ratio <= 1 AND allocation_ratio = ops.round_half_even_numeric_v1(driver_quantity / driver_total_quantity, 12) AND allocated_amount = ops.round_half_even_numeric_v1(reporting_source_amount * allocation_ratio, 6) + rounding_adjustment) OR (allocation_kind = 'UNALLOCATED' AND target_kind = 'UNALLOCATED' AND driver_kind = 'NONE' AND driver_quantity IS NULL AND driver_total_quantity IS NULL AND allocation_ratio IS NULL AND rounding_adjustment = 0 AND allocated_amount > 0 AND allocated_amount <= reporting_source_amount));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_line_amounts CHECK (row_kind <> 'LINE' OR (source_amount >= 0 AND reporting_source_amount >= 0 AND allocated_amount >= 0 AND abs(rounding_adjustment) <= 0.000001));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_fx_shape CHECK (row_kind <> 'LINE' OR (source_currency = currency AND fx_rate_fact_id IS NULL AND reporting_source_amount = source_amount) OR (source_currency <> currency AND fx_rate_fact_id IS NOT NULL));
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_allocation_rule_version_positive CHECK (allocation_rule_version IS NULL OR allocation_rule_version > 0);
ALTER TABLE ops.cost_allocations ADD CONSTRAINT cost_allocations_record_class_fixed CHECK (record_class = 'COMMERCIAL_ACCOUNTING_FACT');
CREATE INDEX cost_allocations_period_revision_fk_idx ON ops.cost_allocations USING btree (period_revision_id, period_revision_row_kind, id);
CREATE INDEX cost_allocations_supersedes_fk_idx ON ops.cost_allocations USING btree (supersedes_period_revision_id, supersedes_period_row_kind, id) WHERE supersedes_period_revision_id IS NOT NULL;
CREATE UNIQUE INDEX cost_allocations_period_header_unique ON ops.cost_allocations USING btree (deployment_id, period_start, period_end, currency, period_version) WHERE row_kind = 'PERIOD';
CREATE UNIQUE INDEX cost_allocations_supersedes_unique ON ops.cost_allocations USING btree (supersedes_period_revision_id) WHERE row_kind = 'PERIOD' AND supersedes_period_revision_id IS NOT NULL;
CREATE UNIQUE INDEX cost_allocations_close_receipt_id_unique ON ops.cost_allocations USING btree (close_receipt_id) WHERE row_kind = 'PERIOD';
CREATE UNIQUE INDEX cost_allocations_close_receipt_digest_unique ON ops.cost_allocations USING btree (close_receipt_digest) WHERE row_kind = 'PERIOD';
CREATE INDEX cost_allocations_period_idx ON ops.cost_allocations USING btree (deployment_id, period_start DESC, period_end DESC, currency, period_version DESC, line_sequence) INCLUDE (row_kind, period_revision_id, record_digest);
CREATE INDEX cost_allocations_period_lines_idx ON ops.cost_allocations USING btree (period_revision_id, line_sequence, id) INCLUDE (allocation_kind, cost_category, target_kind, allocated_amount, record_digest) WHERE row_kind = 'LINE';
CREATE INDEX cost_allocations_source_idx ON ops.cost_allocations USING btree (source_cost_event_id, period_revision_id, line_sequence) INCLUDE (source_effective_digest, reporting_source_amount, allocated_amount) WHERE row_kind = 'LINE';
CREATE INDEX cost_allocations_fx_rate_fk_idx ON ops.cost_allocations USING btree (fx_rate_fact_id, id) INCLUDE (source_currency, currency, reporting_source_amount) WHERE fx_rate_fact_id IS NOT NULL;
CREATE INDEX cost_allocations_job_fk_idx ON ops.cost_allocations USING btree (job_id, period_revision_id, id) INCLUDE (allocated_amount, currency) WHERE job_id IS NOT NULL;
CREATE INDEX cost_allocations_agent_run_fk_idx ON ops.cost_allocations USING btree (agent_run_id, period_revision_id, id) INCLUDE (allocated_amount, currency) WHERE agent_run_id IS NOT NULL;
CREATE INDEX cost_allocations_case_fk_idx ON ops.cost_allocations USING btree (case_id, period_revision_id, id) INCLUDE (allocated_amount, currency) WHERE case_id IS NOT NULL;
CREATE INDEX cost_allocations_outcome_idx ON ops.cost_allocations USING btree (outcome_fact_id, period_start DESC, period_end DESC, id) INCLUDE (allocated_amount, currency, record_digest) WHERE row_kind = 'LINE' AND outcome_fact_id IS NOT NULL;
CREATE INDEX cost_allocations_organization_idx ON ops.cost_allocations USING btree (organization_id, period_start DESC, period_end DESC, id) INCLUDE (allocated_amount, currency, record_digest) WHERE row_kind = 'LINE' AND organization_id IS NOT NULL;
CREATE INDEX cost_allocations_acquisition_idx ON ops.cost_allocations USING btree (organization_id, acquisition_campaign_digest, period_start DESC, id) INCLUDE (allocated_amount, currency, acquisition_source_receipt_digest) WHERE row_kind = 'LINE' AND cost_category = 'SALES_CUSTOMER_ACQUISITION';
CREATE INDEX cost_allocations_acquisition_receipt_fk_idx ON ops.cost_allocations USING btree (acquisition_source_receipt_id, acquisition_source_receipt_digest, id) INCLUDE (organization_id, acquisition_campaign_digest) WHERE acquisition_source_receipt_id IS NOT NULL;
CREATE INDEX cost_allocations_unattributed_acquisition_idx ON ops.cost_allocations USING btree (unattributed_acquisition_pool_digest, period_start DESC, period_end DESC, id) INCLUDE (allocated_amount, currency, source_effective_digest) WHERE row_kind = 'LINE' AND cost_category = 'SALES_CUSTOMER_ACQUISITION' AND acquisition_attribution_state = 'UNATTRIBUTED';
CREATE INDEX cost_allocations_claim_idx ON ops.cost_allocations USING btree (claim_state, period_end DESC, id) INCLUDE (direct_coverage, total_coverage, cost_capture_coverage, close_receipt_digest) WHERE row_kind = 'PERIOD';
REVOKE ALL ON ops.cost_allocations FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.cost_allocations TO gurine_workflow_worker;
GRANT SELECT ON ops.cost_allocations TO gurine_control_api;
GRANT SELECT ON ops.cost_allocations TO gurine_auditor;
CREATE TABLE ops.tariff_versions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  stage ops.tariff_stage NOT NULL,
  currency char(3) NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  effective_from date NOT NULL,
  effective_until date NOT NULL,
  workspace_base_amount numeric(24,6) NOT NULL,
  included_active_contributors integer NOT NULL,
  active_contributor_block_size integer NOT NULL,
  active_contributor_block_amount numeric(24,6) NOT NULL,
  included_processing_credits numeric(24,6) NOT NULL,
  processing_credit_overage_amount numeric(24,6) NOT NULL,
  included_storage_gb_month numeric(24,6) NOT NULL,
  storage_gb_month_overage_amount numeric(24,6) NOT NULL,
  included_api_record_units numeric(24,6) NOT NULL,
  api_record_unit_overage_amount numeric(24,6) NOT NULL,
  sla_add_on_amount numeric(24,6),
  sla_offer_state ops.sla_offer_state NOT NULL,
  sla_policy_version text,
  sla_policy_digest char(64),
  sla_target_availability_ratio numeric(20,18),
  sla_capability_set_digest char(64),
  sla_exclusion_schedule_digest char(64),
  sla_service_credit_schedule_digest char(64),
  sla_measurement_policy_digest char(64),
  sla_policy_source_receipt_digest char(64),
  sla_policy_signature_digest char(64),
  included_signed_webhook_deliveries bigint NOT NULL,
  included_digest_deliveries bigint NOT NULL,
  required_variable_gross_margin_basis_points integer NOT NULL,
  projected_p75_variable_gross_margin_basis_points integer NOT NULL,
  p75_assumption_digest char(64) NOT NULL,
  cost_allocation_period_id uuid NOT NULL,
  cost_allocation_row_kind text NOT NULL,
  cost_allocation_record_digest char(64) NOT NULL,
  cost_allocation_set_digest char(64) NOT NULL,
  cost_allocation_close_receipt_digest char(64) NOT NULL,
  cost_capture_coverage numeric(18,12) NOT NULL,
  direct_cost_coverage numeric(18,12) NOT NULL,
  total_cost_coverage numeric(18,12) NOT NULL,
  p75_revenue_amount numeric(24,6) NOT NULL,
  p75_variable_cost_amount numeric(24,6) NOT NULL,
  margin_formula_digest char(64) NOT NULL,
  margin_evidence_as_of timestamptz NOT NULL,
  margin_exception_reason text,
  margin_exception_expires_at date,
  oversight_approver_id uuid,
  oversight_decision_digest char(64),
  component_set_digest char(64) NOT NULL,
  pricing_policy_digest char(64) NOT NULL,
  tax_policy_digest char(64) NOT NULL,
  proposed_by uuid NOT NULL,
  approver_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_tariff_versions_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.tariff_versions OWNER TO gurine_migrator;
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_effective_start_uq UNIQUE (deployment_id, sku, effective_from);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_context_candidate_uq UNIQUE (id, deployment_id, sku, accounting_timezone);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_record_reference_uq UNIQUE (id, record_digest);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_first_sku_currency_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1' AND currency = 'KRW');
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_interval_ck CHECK (effective_from < effective_until);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_timezone_ck CHECK (length(btrim(accounting_timezone)) BETWEEN 1 AND 63);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_components_ck CHECK (workspace_base_amount > 0 AND included_active_contributors = 10 AND active_contributor_block_size = 10 AND active_contributor_block_amount >= 0 AND included_processing_credits >= 0 AND processing_credit_overage_amount >= 0 AND included_storage_gb_month >= 0 AND storage_gb_month_overage_amount >= 0 AND included_api_record_units >= 0 AND api_record_unit_overage_amount >= 0 AND (sla_add_on_amount IS NULL OR sla_add_on_amount >= 0) AND included_signed_webhook_deliveries >= 0 AND included_digest_deliveries >= 0);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_sla_offer_shape_ck CHECK ((sla_offer_state = 'UNCONFIGURED_NOT_SOLD' AND sla_add_on_amount IS NULL AND sla_policy_version IS NULL AND sla_policy_digest IS NULL AND sla_target_availability_ratio IS NULL AND sla_capability_set_digest IS NULL AND sla_exclusion_schedule_digest IS NULL AND sla_service_credit_schedule_digest IS NULL AND sla_measurement_policy_digest IS NULL AND sla_policy_source_receipt_digest IS NULL AND sla_policy_signature_digest IS NULL) OR (sla_offer_state = 'CONFIGURED_FOR_SALE' AND sla_add_on_amount IS NOT NULL AND sla_add_on_amount > 0 AND sla_policy_version IS NOT NULL AND length(btrim(sla_policy_version)) BETWEEN 1 AND 100 AND sla_policy_digest IS NOT NULL AND sla_target_availability_ratio IS NOT NULL AND sla_target_availability_ratio > 0 AND sla_target_availability_ratio <= 1 AND sla_capability_set_digest IS NOT NULL AND sla_exclusion_schedule_digest IS NOT NULL AND sla_service_credit_schedule_digest IS NOT NULL AND sla_measurement_policy_digest IS NOT NULL AND sla_policy_source_receipt_digest IS NOT NULL AND sla_policy_signature_digest IS NOT NULL));
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_sod_ck CHECK (proposed_by <> approver_id);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_required_margin_ck CHECK ((stage = 'PILOT' AND required_variable_gross_margin_basis_points = 6000) OR (stage = 'GENERAL_AVAILABILITY' AND required_variable_gross_margin_basis_points = 7000));
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_margin_range_ck CHECK (projected_p75_variable_gross_margin_basis_points BETWEEN -100000 AND 10000);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_cost_evidence_kind_ck CHECK (cost_allocation_row_kind = 'PERIOD');
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_cost_evidence_threshold_ck CHECK (cost_capture_coverage BETWEEN 0.99 AND 1 AND direct_cost_coverage = 1 AND total_cost_coverage BETWEEN 0.95 AND 1 AND p75_revenue_amount > 0 AND p75_variable_cost_amount >= 0);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_margin_formula_ck CHECK (projected_p75_variable_gross_margin_basis_points = ops.round_half_even_numeric_v1(((p75_revenue_amount - p75_variable_cost_amount) / p75_revenue_amount) * 10000, 0)::integer);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_margin_exception_ck CHECK (((projected_p75_variable_gross_margin_basis_points >= required_variable_gross_margin_basis_points AND margin_exception_reason IS NULL AND margin_exception_expires_at IS NULL AND oversight_approver_id IS NULL AND oversight_decision_digest IS NULL) OR (stage = 'PILOT' AND projected_p75_variable_gross_margin_basis_points < required_variable_gross_margin_basis_points AND margin_exception_reason IS NOT NULL AND length(btrim(margin_exception_reason)) BETWEEN 1 AND 1000 AND margin_exception_expires_at IS NOT NULL AND margin_exception_expires_at = effective_until AND oversight_approver_id IS NOT NULL AND oversight_approver_id <> proposed_by AND oversight_approver_id <> approver_id AND oversight_decision_digest IS NOT NULL)) IS TRUE);
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_digest_ck CHECK (accounting_policy_digest ~ '^[0-9a-f]{64}$' AND p75_assumption_digest ~ '^[0-9a-f]{64}$' AND cost_allocation_record_digest ~ '^[0-9a-f]{64}$' AND cost_allocation_set_digest ~ '^[0-9a-f]{64}$' AND cost_allocation_close_receipt_digest ~ '^[0-9a-f]{64}$' AND margin_formula_digest ~ '^[0-9a-f]{64}$' AND component_set_digest ~ '^[0-9a-f]{64}$' AND pricing_policy_digest ~ '^[0-9a-f]{64}$' AND tax_policy_digest ~ '^[0-9a-f]{64}$' AND decision_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$' AND (oversight_decision_digest IS NULL OR oversight_decision_digest ~ '^[0-9a-f]{64}$') AND (sla_policy_digest IS NULL OR sla_policy_digest ~ '^[0-9a-f]{64}$') AND (sla_capability_set_digest IS NULL OR sla_capability_set_digest ~ '^[0-9a-f]{64}$') AND (sla_exclusion_schedule_digest IS NULL OR sla_exclusion_schedule_digest ~ '^[0-9a-f]{64}$') AND (sla_service_credit_schedule_digest IS NULL OR sla_service_credit_schedule_digest ~ '^[0-9a-f]{64}$') AND (sla_measurement_policy_digest IS NULL OR sla_measurement_policy_digest ~ '^[0-9a-f]{64}$') AND (sla_policy_source_receipt_digest IS NULL OR sla_policy_source_receipt_digest ~ '^[0-9a-f]{64}$') AND (sla_policy_signature_digest IS NULL OR sla_policy_signature_digest ~ '^[0-9a-f]{64}$'));
CREATE INDEX tariff_effective_lookup_idx ON ops.tariff_versions USING btree (deployment_id, sku, effective_from DESC, effective_until, id);
CREATE INDEX tariff_stage_lookup_idx ON ops.tariff_versions USING btree (deployment_id, stage, effective_from DESC, id);
CREATE INDEX tariff_proposer_fk_idx ON ops.tariff_versions USING btree (proposed_by, id);
CREATE INDEX tariff_approver_fk_idx ON ops.tariff_versions USING btree (approver_id, id);
CREATE INDEX tariff_oversight_approver_fk_idx ON ops.tariff_versions USING btree (oversight_approver_id, id) WHERE oversight_approver_id IS NOT NULL;
CREATE INDEX tariff_cost_allocation_fk_idx ON ops.tariff_versions USING btree (cost_allocation_period_id, cost_allocation_row_kind, id);
REVOKE ALL ON ops.tariff_versions FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.tariff_versions TO gurine_workflow_worker;
GRANT SELECT ON ops.tariff_versions TO gurine_control_api;
GRANT SELECT ON ops.tariff_versions TO gurine_auditor;
CREATE TABLE ops.commercial_contract_periods (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  root_contract_period_id uuid NOT NULL,
  revision bigint NOT NULL,
  fact_effect ops.commercial_period_fact_effect NOT NULL,
  supersedes_contract_period_id uuid,
  predecessor_record_digest char(64),
  contract_reference_hmac char(64) NOT NULL,
  contract_reference_hmac_key_version text NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  sku ops.commercial_sku NOT NULL,
  tariff_version_id uuid NOT NULL,
  tariff_record_digest char(64) NOT NULL,
  qualification_receipt_id uuid NOT NULL,
  qualification_episode_id uuid NOT NULL,
  qualification_receipt_digest char(64) NOT NULL,
  offer_contract_binding_digest char(64) NOT NULL,
  offer_profile_id uuid NOT NULL,
  offer_profile_version bigint NOT NULL,
  offer_profile_digest char(64) NOT NULL,
  offer_capability_set_digest char(64) NOT NULL,
  offer_quota_set_digest char(64) NOT NULL,
  offer_overage_policy_set_digest char(64) NOT NULL,
  offer_service_credit_policy_digest char(64) NOT NULL,
  offer_effective_from timestamptz NOT NULL,
  offer_effective_until timestamptz NOT NULL,
  offer_source_receipt_digest char(64) NOT NULL,
  offer_signature_digest char(64) NOT NULL,
  currency char(3) NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  binding_committed_amount numeric(24,6) NOT NULL,
  commitment_policy_digest char(64) NOT NULL,
  status ops.commercial_contract_status NOT NULL,
  stage ops.tariff_stage NOT NULL,
  provisioning_state ops.commercial_provisioning_state NOT NULL,
  sla_add_on_selected boolean NOT NULL,
  sla_selection_state ops.sla_selection_state NOT NULL,
  sla_policy_version text,
  sla_policy_digest char(64),
  sla_target_availability_ratio numeric(20,18),
  sla_capability_set_digest char(64),
  sla_exclusion_schedule_digest char(64),
  sla_service_credit_schedule_digest char(64),
  sla_measurement_policy_digest char(64),
  signed_at timestamptz NOT NULL,
  provisioned_at timestamptz,
  state_effective_at timestamptz NOT NULL,
  deployment_configuration_digest char(64) NOT NULL,
  authority_reference_digest char(64) NOT NULL,
  approver_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_commercial_contract_periods_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.commercial_contract_periods OWNER TO gurine_migrator;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_root_revision_uq UNIQUE (root_contract_period_id, revision);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_semantic_revision_uq UNIQUE (deployment_id, organization_id, contract_id, period_start, revision);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_context_candidate_uq UNIQUE (id, deployment_id, organization_id, contract_id, sku, accounting_timezone);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_offer_binding_uq UNIQUE (id, offer_profile_id, offer_profile_version, offer_profile_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_offer_child_uq UNIQUE (id, offer_profile_id, offer_profile_version, offer_profile_digest, offer_capability_set_digest, offer_quota_set_digest, offer_overage_policy_set_digest, offer_service_credit_policy_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_paid_packet_binding_uq UNIQUE (id, deployment_id, organization_id, sku, revision, record_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_sla_candidate_uq UNIQUE (id, organization_id, sla_policy_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_invalidation_binding_uq UNIQUE (id, revision, record_digest);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_revision_ck CHECK (revision > 0);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_chain_shape_ck CHECK (((fact_effect = 'ORIGINAL' AND revision = 1 AND root_contract_period_id = id AND supersedes_contract_period_id IS NULL AND predecessor_record_digest IS NULL) OR (fact_effect = 'REPLACEMENT' AND revision > 1 AND root_contract_period_id <> id AND supersedes_contract_period_id IS NOT NULL AND predecessor_record_digest IS NOT NULL)) IS TRUE);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_interval_ck CHECK (period_start < period_end);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_offer_version_interval_ck CHECK (offer_profile_version > 0 AND offer_effective_from < offer_effective_until);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_currency_timezone_ck CHECK (currency ~ '^[A-Z]{3}$' AND length(btrim(accounting_timezone)) BETWEEN 1 AND 63 AND binding_committed_amount >= 0);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_provisioning_ck CHECK ((provisioning_state = 'UNPROVISIONED' AND provisioned_at IS NULL) OR (provisioning_state = 'PROVISIONED' AND provisioned_at IS NOT NULL AND provisioned_at >= signed_at));
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_state_effective_ck CHECK (state_effective_at >= signed_at AND (provisioned_at IS NULL OR state_effective_at >= provisioned_at));
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_sla_selection_shape_ck CHECK ((sla_selection_state = 'UNAVAILABLE_NOT_SOLD' AND sla_add_on_selected = false AND sla_policy_version IS NULL AND sla_policy_digest IS NULL AND sla_target_availability_ratio IS NULL AND sla_capability_set_digest IS NULL AND sla_exclusion_schedule_digest IS NULL AND sla_service_credit_schedule_digest IS NULL AND sla_measurement_policy_digest IS NULL) OR (sla_selection_state = 'AVAILABLE_NOT_SELECTED' AND sla_add_on_selected = false AND sla_policy_version IS NULL AND sla_policy_digest IS NULL AND sla_target_availability_ratio IS NULL AND sla_capability_set_digest IS NULL AND sla_exclusion_schedule_digest IS NULL AND sla_service_credit_schedule_digest IS NULL AND sla_measurement_policy_digest IS NULL) OR (sla_selection_state = 'SELECTED' AND sla_add_on_selected = true AND sla_policy_version IS NOT NULL AND length(btrim(sla_policy_version)) BETWEEN 1 AND 100 AND sla_policy_digest IS NOT NULL AND sla_target_availability_ratio IS NOT NULL AND sla_target_availability_ratio > 0 AND sla_target_availability_ratio <= 1 AND sla_capability_set_digest IS NOT NULL AND sla_exclusion_schedule_digest IS NOT NULL AND sla_service_credit_schedule_digest IS NOT NULL AND sla_measurement_policy_digest IS NOT NULL));
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_hmac_key_version_ck CHECK (length(btrim(contract_reference_hmac_key_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_digest_ck CHECK ((predecessor_record_digest IS NULL OR predecessor_record_digest ~ '^[0-9a-f]{64}$') AND contract_reference_hmac ~ '^[0-9a-f]{64}$' AND tariff_record_digest ~ '^[0-9a-f]{64}$' AND qualification_receipt_digest ~ '^[0-9a-f]{64}$' AND offer_contract_binding_digest ~ '^[0-9a-f]{64}$' AND offer_profile_digest ~ '^[0-9a-f]{64}$' AND offer_capability_set_digest ~ '^[0-9a-f]{64}$' AND offer_quota_set_digest ~ '^[0-9a-f]{64}$' AND offer_overage_policy_set_digest ~ '^[0-9a-f]{64}$' AND offer_service_credit_policy_digest ~ '^[0-9a-f]{64}$' AND offer_source_receipt_digest ~ '^[0-9a-f]{64}$' AND offer_signature_digest ~ '^[0-9a-f]{64}$' AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND commitment_policy_digest ~ '^[0-9a-f]{64}$' AND deployment_configuration_digest ~ '^[0-9a-f]{64}$' AND authority_reference_digest ~ '^[0-9a-f]{64}$' AND decision_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$' AND (sla_policy_digest IS NULL OR sla_policy_digest ~ '^[0-9a-f]{64}$') AND (sla_capability_set_digest IS NULL OR sla_capability_set_digest ~ '^[0-9a-f]{64}$') AND (sla_exclusion_schedule_digest IS NULL OR sla_exclusion_schedule_digest ~ '^[0-9a-f]{64}$') AND (sla_service_credit_schedule_digest IS NULL OR sla_service_credit_schedule_digest ~ '^[0-9a-f]{64}$') AND (sla_measurement_policy_digest IS NULL OR sla_measurement_policy_digest ~ '^[0-9a-f]{64}$'));
CREATE UNIQUE INDEX contract_period_one_successor_uq ON ops.commercial_contract_periods USING btree (supersedes_contract_period_id) WHERE supersedes_contract_period_id IS NOT NULL;
CREATE INDEX contract_period_org_lookup_idx ON ops.commercial_contract_periods USING btree (deployment_id, organization_id, period_start DESC, id);
CREATE INDEX contract_period_contract_history_idx ON ops.commercial_contract_periods USING btree (contract_id, period_start ASC, id ASC);
CREATE INDEX contract_period_status_idx ON ops.commercial_contract_periods USING btree (deployment_id, status, period_end, id);
CREATE INDEX contract_period_tariff_fk_idx ON ops.commercial_contract_periods USING btree (tariff_version_id, deployment_id, sku, accounting_timezone, id);
CREATE INDEX contract_period_approver_fk_idx ON ops.commercial_contract_periods USING btree (approver_id, id);
CREATE INDEX contract_period_state_effective_idx ON ops.commercial_contract_periods USING btree (deployment_id, organization_id, contract_id, state_effective_at ASC, revision ASC, id ASC);
CREATE UNIQUE INDEX contract_period_offer_identity_original_uq ON ops.commercial_contract_periods USING btree (offer_profile_id, offer_profile_version) WHERE fact_effect = 'ORIGINAL';
CREATE UNIQUE INDEX contract_period_offer_digest_original_uq ON ops.commercial_contract_periods USING btree (offer_profile_digest) WHERE fact_effect = 'ORIGINAL';
REVOKE ALL ON ops.commercial_contract_periods FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.commercial_contract_periods TO gurine_workflow_worker;
GRANT SELECT ON ops.commercial_contract_periods TO gurine_control_api;
GRANT SELECT ON ops.commercial_contract_periods TO gurine_auditor;
CREATE TABLE ops.usage_window_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_receipt_id uuid NOT NULL,
  receipt_version bigint NOT NULL,
  receipt_effect ops.usage_receipt_effect NOT NULL,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  tariff_version_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  measurement_window_digest char(64) NOT NULL,
  receipt_kind ops.usage_receipt_kind NOT NULL,
  meter_kind ops.usage_meter_kind NOT NULL,
  unit ops.usage_unit NOT NULL,
  measurement_state ops.usage_measurement_state NOT NULL,
  expected_item_count bigint NOT NULL,
  observed_item_count bigint NOT NULL,
  observed_quantity numeric(24,6),
  normalization_basis_kind ops.usage_normalization_basis_kind NOT NULL,
  normalization_input_quantity numeric(24,6),
  coverage_digest char(64) NOT NULL,
  source_system_id text NOT NULL,
  source_window_identity_hmac char(64) NOT NULL,
  source_window_hmac_key_version text NOT NULL,
  source_cursor_set_digest char(64) NOT NULL,
  source_record_set_digest char(64) NOT NULL,
  source_signature_digest char(64) NOT NULL,
  meter_policy_version text NOT NULL,
  meter_policy_digest char(64) NOT NULL,
  measured_at timestamptz NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_usage_window_receipts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.usage_window_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_root_version_uq UNIQUE (root_receipt_id, receipt_version);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_identity_version_uq UNIQUE (deployment_id, organization_id, receipt_kind, meter_kind, measurement_window_digest, receipt_version);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_reference_uq UNIQUE (id, receipt_version, receipt_digest);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_version_ck CHECK (receipt_version > 0);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_chain_ck CHECK ((receipt_effect = 'ORIGINAL' AND receipt_version = 1 AND root_receipt_id = id AND supersedes_receipt_id IS NULL AND predecessor_receipt_digest IS NULL) OR (receipt_effect IN ('REPLACEMENT','REVERSAL') AND receipt_version > 1 AND root_receipt_id <> id AND supersedes_receipt_id IS NOT NULL AND predecessor_receipt_digest IS NOT NULL));
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_period_ck CHECK (period_start < period_end);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_count_ck CHECK (expected_item_count >= 0 AND observed_item_count >= 0 AND observed_item_count <= expected_item_count);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_measurement_ck CHECK ((receipt_effect <> 'REVERSAL' AND measurement_state = 'COMPLETE' AND observed_item_count = expected_item_count AND observed_quantity IS NOT NULL AND observed_quantity >= 0 AND normalization_input_quantity IS NOT NULL AND normalization_input_quantity >= 0) OR (receipt_effect <> 'REVERSAL' AND measurement_state IN ('PARTIAL','UNKNOWN') AND observed_quantity IS NULL AND normalization_input_quantity IS NULL) OR (receipt_effect = 'REVERSAL' AND measurement_state = 'UNKNOWN' AND observed_quantity IS NULL AND normalization_input_quantity IS NULL));
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_kind_ck CHECK ((meter_kind = 'SEAT' AND receipt_kind = 'IDENTITY_USAGE_WINDOW' AND unit = 'COUNT' AND normalization_basis_kind = 'ACTIVE_CONTRIBUTOR_COUNT') OR (meter_kind = 'AGENT_TOKEN' AND receipt_kind = 'AGENT_USAGE_WINDOW' AND unit = 'TOKEN' AND normalization_basis_kind = 'AGENT_TOKEN_COUNT') OR (meter_kind = 'MODEL_REQUEST' AND receipt_kind = 'MODEL_USAGE_WINDOW' AND unit = 'REQUEST' AND normalization_basis_kind = 'MODEL_REQUEST_COST_UNIT') OR (meter_kind = 'SOURCE_PAGE' AND receipt_kind = 'SOURCE_USAGE_WINDOW' AND unit = 'PAGE' AND normalization_basis_kind = 'SOURCE_PAGE_COUNT') OR (meter_kind = 'STORAGE_BYTE_HOUR' AND receipt_kind = 'STORAGE_USAGE_WINDOW' AND unit = 'BYTE_HOUR' AND normalization_basis_kind = 'ENCRYPTED_BYTE_HOUR') OR (meter_kind = 'DELIVERY_ATTEMPT' AND receipt_kind = 'DELIVERY_USAGE_WINDOW' AND unit = 'ATTEMPT' AND normalization_basis_kind = 'DELIVERY_ATTEMPT_COUNT') OR (meter_kind = 'EXPORT_BYTE' AND receipt_kind = 'EXPORT_USAGE_WINDOW' AND unit = 'BYTE' AND normalization_basis_kind = 'EXPORT_BYTE_COUNT') OR (meter_kind = 'API_REQUEST' AND receipt_kind = 'API_USAGE_WINDOW' AND unit = 'REQUEST' AND normalization_basis_kind = 'API_RECORD_RETURNED_COUNT'));
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_source_ck CHECK (source_system_id ~ '^[a-z0-9][a-z0-9._-]{0,127}$' AND length(btrim(source_window_hmac_key_version)) BETWEEN 1 AND 100 AND length(btrim(meter_policy_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_time_ck CHECK (measured_at <= created_at);
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_digest_ck CHECK ((predecessor_receipt_digest IS NULL OR predecessor_receipt_digest ~ '^[0-9a-f]{64}$') AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND measurement_window_digest ~ '^[0-9a-f]{64}$' AND coverage_digest ~ '^[0-9a-f]{64}$' AND source_window_identity_hmac ~ '^[0-9a-f]{64}$' AND source_cursor_set_digest ~ '^[0-9a-f]{64}$' AND source_record_set_digest ~ '^[0-9a-f]{64}$' AND source_signature_digest ~ '^[0-9a-f]{64}$' AND meter_policy_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX usage_window_receipt_one_successor_uq ON ops.usage_window_receipts USING btree (supersedes_receipt_id) WHERE supersedes_receipt_id IS NOT NULL;
CREATE INDEX usage_window_receipt_root_history_idx ON ops.usage_window_receipts USING btree (root_receipt_id, receipt_version ASC, id ASC);
CREATE INDEX usage_window_receipt_contract_fk_idx ON ops.usage_window_receipts USING btree (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone, id);
CREATE INDEX usage_window_receipt_tariff_fk_idx ON ops.usage_window_receipts USING btree (tariff_version_id, deployment_id, sku, accounting_timezone, id);
CREATE INDEX usage_window_receipt_invoice_idx ON ops.usage_window_receipts USING btree (organization_id, period_start ASC, period_end ASC, meter_kind, receipt_version DESC, id ASC);
CREATE INDEX usage_window_receipt_source_idx ON ops.usage_window_receipts USING btree (source_system_id, source_window_identity_hmac, receipt_version DESC, id ASC);
REVOKE ALL ON ops.usage_window_receipts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.usage_window_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.usage_window_receipts TO gurine_control_api;
GRANT SELECT ON ops.usage_window_receipts TO gurine_auditor;
CREATE TABLE ops.usage_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_usage_fact_id uuid NOT NULL,
  revision bigint NOT NULL,
  fact_effect ops.usage_fact_effect NOT NULL,
  supersedes_usage_fact_id uuid,
  predecessor_record_digest char(64),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  tariff_version_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  measurement_window_digest char(64) NOT NULL,
  measurement_state ops.usage_measurement_state NOT NULL,
  expected_item_count bigint NOT NULL,
  observed_item_count bigint NOT NULL,
  coverage_digest char(64) NOT NULL,
  meter_kind ops.usage_meter_kind NOT NULL,
  unit ops.usage_unit NOT NULL,
  quantity numeric(24,6),
  billable_metric ops.billable_metric NOT NULL,
  billable_quantity numeric(24,6),
  billable_unit ops.billable_unit NOT NULL,
  conversion_policy_digest char(64) NOT NULL,
  source_receipt_kind ops.usage_receipt_kind NOT NULL,
  source_receipt_id uuid NOT NULL,
  source_receipt_version bigint NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  meter_policy_version text NOT NULL,
  meter_policy_digest char(64) NOT NULL,
  measured_at timestamptz NOT NULL,
  record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_usage_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.usage_facts OWNER TO gurine_migrator;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_root_revision_uq UNIQUE (root_usage_fact_id, revision);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_window_revision_uq UNIQUE (deployment_id, organization_id, meter_kind, measurement_window_digest, revision);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_record_reference_uq UNIQUE (id, record_digest);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_membership_reference_uq UNIQUE (id, root_usage_fact_id, revision, record_digest);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_revision_ck CHECK (revision > 0);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_chain_shape_ck CHECK (((fact_effect = 'ORIGINAL' AND revision = 1 AND root_usage_fact_id = id AND supersedes_usage_fact_id IS NULL AND predecessor_record_digest IS NULL) OR (fact_effect IN ('REPLACEMENT','REVERSAL') AND revision > 1 AND root_usage_fact_id <> id AND supersedes_usage_fact_id IS NOT NULL AND predecessor_record_digest IS NOT NULL)) IS TRUE);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_interval_ck CHECK (period_start < period_end);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_timezone_ck CHECK (length(btrim(accounting_timezone)) BETWEEN 1 AND 63);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_counts_ck CHECK (expected_item_count >= 0 AND observed_item_count >= 0 AND observed_item_count <= expected_item_count);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_measurement_state_ck CHECK (((measurement_state = 'COMPLETE' AND fact_effect <> 'REVERSAL' AND observed_item_count = expected_item_count AND quantity IS NOT NULL AND quantity >= 0 AND billable_quantity IS NOT NULL AND billable_quantity >= 0) OR (measurement_state IN ('PARTIAL','UNKNOWN') AND quantity IS NULL AND billable_quantity IS NULL) OR (fact_effect = 'REVERSAL' AND measurement_state = 'UNKNOWN' AND quantity IS NULL AND billable_quantity IS NULL)) IS TRUE);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_receipt_version_ck CHECK (source_receipt_version > 0);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_unit_ck CHECK ((meter_kind = 'SEAT' AND unit = 'COUNT' AND source_receipt_kind = 'IDENTITY_USAGE_WINDOW' AND billable_metric = 'ACTIVE_CONTRIBUTOR' AND billable_unit = 'CONTRIBUTOR_MONTH') OR (meter_kind = 'AGENT_TOKEN' AND unit = 'TOKEN' AND source_receipt_kind = 'AGENT_USAGE_WINDOW' AND billable_metric = 'PROCESSING_CREDIT' AND billable_unit = 'CREDIT') OR (meter_kind = 'MODEL_REQUEST' AND unit = 'REQUEST' AND source_receipt_kind = 'MODEL_USAGE_WINDOW' AND billable_metric = 'PROCESSING_CREDIT' AND billable_unit = 'CREDIT') OR (meter_kind = 'SOURCE_PAGE' AND unit = 'PAGE' AND source_receipt_kind = 'SOURCE_USAGE_WINDOW' AND billable_metric = 'PROCESSING_CREDIT' AND billable_unit = 'CREDIT') OR (meter_kind = 'STORAGE_BYTE_HOUR' AND unit = 'BYTE_HOUR' AND source_receipt_kind = 'STORAGE_USAGE_WINDOW' AND billable_metric = 'STORAGE_GB_MONTH' AND billable_unit = 'GB_MONTH') OR (meter_kind = 'DELIVERY_ATTEMPT' AND unit = 'ATTEMPT' AND source_receipt_kind = 'DELIVERY_USAGE_WINDOW' AND billable_metric = 'INCLUDED_DELIVERY' AND billable_unit = 'ATTEMPT') OR (meter_kind = 'EXPORT_BYTE' AND unit = 'BYTE' AND source_receipt_kind = 'EXPORT_USAGE_WINDOW' AND billable_metric = 'INCLUDED_EXPORT' AND billable_unit = 'BYTE') OR (meter_kind = 'API_REQUEST' AND unit = 'REQUEST' AND source_receipt_kind = 'API_USAGE_WINDOW' AND billable_metric = 'API_RECORD_UNIT' AND billable_unit = 'KILO_RECORDS'));
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_policy_version_ck CHECK (length(btrim(meter_policy_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_digest_ck CHECK ((predecessor_record_digest IS NULL OR predecessor_record_digest ~ '^[0-9a-f]{64}$') AND measurement_window_digest ~ '^[0-9a-f]{64}$' AND coverage_digest ~ '^[0-9a-f]{64}$' AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND conversion_policy_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND meter_policy_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX usage_fact_one_successor_uq ON ops.usage_facts USING btree (supersedes_usage_fact_id) WHERE supersedes_usage_fact_id IS NOT NULL;
CREATE INDEX usage_fact_invoice_window_idx ON ops.usage_facts USING btree (organization_id, period_start ASC, period_end ASC, meter_kind, id);
CREATE INDEX usage_fact_tariff_idx ON ops.usage_facts USING btree (tariff_version_id, meter_kind, period_start ASC, id);
CREATE INDEX usage_fact_source_idx ON ops.usage_facts USING btree (source_receipt_kind, source_receipt_id, source_receipt_version, id);
CREATE INDEX usage_fact_contract_fk_idx ON ops.usage_facts USING btree (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone, id);
CREATE INDEX usage_fact_tariff_fk_idx ON ops.usage_facts USING btree (tariff_version_id, deployment_id, sku, accounting_timezone, id);
CREATE INDEX usage_fact_source_receipt_fk_idx ON ops.usage_facts USING btree (source_receipt_id, source_receipt_version, source_receipt_digest, id);
REVOKE ALL ON ops.usage_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.usage_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.usage_facts TO gurine_control_api;
GRANT SELECT ON ops.usage_facts TO gurine_auditor;
CREATE TABLE ops.discount_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  tariff_version_id uuid NOT NULL,
  tariff_record_digest char(64) NOT NULL,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  root_discount_id uuid NOT NULL,
  revision bigint NOT NULL,
  state ops.discount_state NOT NULL,
  supersedes_discount_id uuid,
  applies_workspace_base boolean NOT NULL,
  applies_active_contributor_block boolean NOT NULL,
  applies_processing_credit_overage boolean NOT NULL,
  applies_storage_gb_month_overage boolean NOT NULL,
  applies_api_record_unit_overage boolean NOT NULL,
  applies_sla_add_on boolean NOT NULL,
  basis_points integer,
  reason_code ops.discount_reason NOT NULL,
  effective_from date NOT NULL,
  effective_until date NOT NULL,
  required_variable_gross_margin_basis_points integer,
  projected_margin_after_discount_basis_points integer,
  margin_assumption_digest char(64),
  resulting_discount_set_digest char(64) NOT NULL,
  undiscounted_p75_revenue_amount numeric(24,6) NOT NULL,
  discounted_p75_revenue_amount numeric(24,6) NOT NULL,
  p75_variable_cost_amount numeric(24,6) NOT NULL,
  cost_evidence_digest char(64) NOT NULL,
  margin_formula_digest char(64) NOT NULL,
  margin_evidence_as_of timestamptz NOT NULL,
  oversight_reason text,
  oversight_expires_at date,
  oversight_approver_id uuid,
  oversight_decision_digest char(64),
  proposed_by uuid NOT NULL,
  approver_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_discount_decisions_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.discount_decisions OWNER TO gurine_migrator;
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_root_revision_uq UNIQUE (root_discount_id, revision);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_record_reference_uq UNIQUE (id, record_digest);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_scope_nonempty_ck CHECK (applies_workspace_base OR applies_active_contributor_block OR applies_processing_credit_overage OR applies_storage_gb_month_overage OR applies_api_record_unit_overage OR applies_sla_add_on);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_interval_ck CHECK (effective_from < effective_until);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_timezone_ck CHECK (length(btrim(accounting_timezone)) BETWEEN 1 AND 63);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_sod_ck CHECK (proposed_by <> approver_id);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_chain_shape_ck CHECK ((revision = 1 AND root_discount_id = id AND supersedes_discount_id IS NULL) OR (revision > 1 AND root_discount_id <> id AND supersedes_discount_id IS NOT NULL));
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_value_ck CHECK ((((state = 'ACTIVE' AND basis_points IS NOT NULL AND basis_points BETWEEN 1 AND 10000) OR (state = 'WITHDRAWN' AND basis_points IS NULL)) AND required_variable_gross_margin_basis_points IS NOT NULL AND projected_margin_after_discount_basis_points IS NOT NULL AND projected_margin_after_discount_basis_points BETWEEN -100000 AND 10000 AND margin_assumption_digest IS NOT NULL AND undiscounted_p75_revenue_amount > 0 AND discounted_p75_revenue_amount > 0 AND discounted_p75_revenue_amount <= undiscounted_p75_revenue_amount AND p75_variable_cost_amount >= 0) IS TRUE);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_margin_formula_ck CHECK (projected_margin_after_discount_basis_points = ops.round_half_even_numeric_v1(((discounted_p75_revenue_amount - p75_variable_cost_amount) / discounted_p75_revenue_amount) * 10000, 0)::integer);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_margin_exception_ck CHECK (((projected_margin_after_discount_basis_points IS NOT NULL AND required_variable_gross_margin_basis_points IS NOT NULL AND projected_margin_after_discount_basis_points >= required_variable_gross_margin_basis_points AND oversight_reason IS NULL AND oversight_expires_at IS NULL AND oversight_approver_id IS NULL AND oversight_decision_digest IS NULL) OR (projected_margin_after_discount_basis_points IS NOT NULL AND required_variable_gross_margin_basis_points IS NOT NULL AND projected_margin_after_discount_basis_points < required_variable_gross_margin_basis_points AND oversight_reason IS NOT NULL AND length(btrim(oversight_reason)) BETWEEN 1 AND 1000 AND oversight_expires_at IS NOT NULL AND oversight_expires_at = effective_until AND oversight_approver_id IS NOT NULL AND oversight_approver_id <> proposed_by AND oversight_approver_id <> approver_id AND oversight_decision_digest IS NOT NULL)) IS TRUE);
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_digest_ck CHECK (tariff_record_digest ~ '^[0-9a-f]{64}$' AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND decision_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$' AND margin_assumption_digest ~ '^[0-9a-f]{64}$' AND resulting_discount_set_digest ~ '^[0-9a-f]{64}$' AND cost_evidence_digest ~ '^[0-9a-f]{64}$' AND margin_formula_digest ~ '^[0-9a-f]{64}$' AND (oversight_decision_digest IS NULL OR oversight_decision_digest ~ '^[0-9a-f]{64}$'));
CREATE UNIQUE INDEX discount_one_successor_uq ON ops.discount_decisions USING btree (supersedes_discount_id) WHERE supersedes_discount_id IS NOT NULL;
CREATE INDEX discount_effective_lookup_idx ON ops.discount_decisions USING btree (organization_id, contract_period_id, effective_from ASC, effective_until ASC, id);
CREATE INDEX discount_root_history_idx ON ops.discount_decisions USING btree (root_discount_id, revision ASC, id);
CREATE INDEX discount_contract_fk_idx ON ops.discount_decisions USING btree (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone, id);
CREATE INDEX discount_tariff_fk_idx ON ops.discount_decisions USING btree (tariff_version_id, deployment_id, sku, accounting_timezone, id);
CREATE INDEX discount_proposer_fk_idx ON ops.discount_decisions USING btree (proposed_by, id);
CREATE INDEX discount_approver_fk_idx ON ops.discount_decisions USING btree (approver_id, id);
CREATE INDEX discount_oversight_approver_fk_idx ON ops.discount_decisions USING btree (oversight_approver_id, id) WHERE oversight_approver_id IS NOT NULL;
REVOKE ALL ON ops.discount_decisions FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.discount_decisions TO gurine_workflow_worker;
GRANT SELECT ON ops.discount_decisions TO gurine_control_api;
GRANT SELECT ON ops.discount_decisions TO gurine_auditor;
CREATE TABLE ops.invoice_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_invoice_id uuid NOT NULL,
  invoice_revision bigint NOT NULL,
  invoice_effect ops.invoice_fact_effect NOT NULL,
  supersedes_invoice_id uuid,
  predecessor_reconciliation_digest char(64),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  accounting_timezone text NOT NULL,
  source_system_id text NOT NULL,
  external_invoice_reference_digest char(64) NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  billing_cutoff_at timestamptz NOT NULL,
  currency char(3) NOT NULL,
  line_count integer NOT NULL,
  line_set_digest char(64) NOT NULL,
  expected_usage_membership_count integer NOT NULL,
  usage_membership_count integer NOT NULL,
  usage_membership_set_digest char(64) NOT NULL,
  usage_fact_set_digest char(64) NOT NULL,
  usage_window_receipt_set_digest char(64) NOT NULL,
  tariff_set_digest char(64) NOT NULL,
  discount_leaf_set_digest char(64) NOT NULL,
  correction_set_digest char(64) NOT NULL,
  contract_state_interval_set_digest char(64) NOT NULL,
  tax_policy_digest char(64) NOT NULL,
  rounding_policy_digest char(64) NOT NULL,
  subtotal numeric(24,6) NOT NULL,
  discount_total numeric(24,6) NOT NULL,
  taxable_amount numeric(24,6) NOT NULL,
  tax_total numeric(24,6) NOT NULL,
  correction_total numeric(24,6) NOT NULL,
  invoice_total numeric(24,6) NOT NULL,
  provider_receipt_digest char(64) NOT NULL,
  source_record_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  import_receipt_digest char(64) NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  reconciliation_digest char(64) NOT NULL,
  reconciled_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_invoice_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.invoice_facts OWNER TO gurine_migrator;
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_reconciliation_digest_uq UNIQUE (reconciliation_digest);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_import_receipt_uq UNIQUE (import_receipt_digest);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_root_revision_uq UNIQUE (root_invoice_id, invoice_revision);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_source_identity_revision_uq UNIQUE (deployment_id, source_system_id, external_invoice_reference_digest, invoice_revision);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_chain_reference_uq UNIQUE (id, root_invoice_id, reconciliation_digest);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_scope_uq UNIQUE (id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_currency_uq UNIQUE (id, currency);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_revision_ck CHECK (invoice_revision > 0);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_chain_shape_ck CHECK ((invoice_effect = 'ORIGINAL' AND invoice_revision = 1 AND root_invoice_id = id AND supersedes_invoice_id IS NULL AND predecessor_reconciliation_digest IS NULL) OR (invoice_effect = 'RESTATEMENT' AND invoice_revision > 1 AND root_invoice_id <> id AND supersedes_invoice_id IS NOT NULL AND predecessor_reconciliation_digest IS NOT NULL));
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_source_system_ck CHECK (source_system_id ~ '^[a-z0-9][a-z0-9._-]{0,127}$');
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_timezone_shape_ck CHECK (accounting_timezone = btrim(accounting_timezone) AND octet_length(accounting_timezone) BETWEEN 1 AND 255);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_period_ck CHECK (period_end > period_start);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_currency_ck CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_line_count_ck CHECK (line_count > 0 AND expected_usage_membership_count > 0 AND usage_membership_count = expected_usage_membership_count);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_nonnegative_amounts_ck CHECK (subtotal >= 0 AND discount_total >= 0 AND taxable_amount >= 0 AND tax_total >= 0 AND invoice_total >= 0);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_discount_bound_ck CHECK (discount_total <= subtotal);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_taxable_conservation_ck CHECK (taxable_amount = subtotal - discount_total);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_total_conservation_ck CHECK (invoice_total = taxable_amount + tax_total + correction_total);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_time_ck CHECK (billing_cutoff_at <= reconciled_at AND reconciled_at <= recorded_at);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_digests_ck CHECK ((predecessor_reconciliation_digest IS NULL OR predecessor_reconciliation_digest ~ '^[0-9a-f]{64}$') AND external_invoice_reference_digest ~ '^[0-9a-f]{64}$' AND line_set_digest ~ '^[0-9a-f]{64}$' AND usage_membership_set_digest ~ '^[0-9a-f]{64}$' AND usage_fact_set_digest ~ '^[0-9a-f]{64}$' AND usage_window_receipt_set_digest ~ '^[0-9a-f]{64}$' AND tariff_set_digest ~ '^[0-9a-f]{64}$' AND discount_leaf_set_digest ~ '^[0-9a-f]{64}$' AND correction_set_digest ~ '^[0-9a-f]{64}$' AND contract_state_interval_set_digest ~ '^[0-9a-f]{64}$' AND tax_policy_digest ~ '^[0-9a-f]{64}$' AND rounding_policy_digest ~ '^[0-9a-f]{64}$' AND provider_receipt_digest ~ '^[0-9a-f]{64}$' AND source_record_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND import_receipt_digest ~ '^[0-9a-f]{64}$' AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND reconciliation_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX invoice_facts_one_successor_uq ON ops.invoice_facts USING btree (supersedes_invoice_id) WHERE supersedes_invoice_id IS NOT NULL;
CREATE INDEX invoice_facts_root_history_idx ON ops.invoice_facts USING btree (root_invoice_id, invoice_revision, id);
CREATE INDEX invoice_facts_scope_period_idx ON ops.invoice_facts USING btree (deployment_id, organization_id, period_start DESC, period_end DESC, id);
CREATE INDEX invoice_facts_contract_idx ON ops.invoice_facts USING btree (contract_id, period_start DESC, id);
CREATE INDEX invoice_facts_recorded_idx ON ops.invoice_facts USING btree (recorded_at DESC, id);
CREATE INDEX invoice_facts_contract_period_fk_idx ON ops.invoice_facts USING btree (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone, id);
CREATE INDEX invoice_facts_supersedes_fk_idx ON ops.invoice_facts USING btree (supersedes_invoice_id, root_invoice_id, predecessor_reconciliation_digest, id) WHERE supersedes_invoice_id IS NOT NULL;
REVOKE ALL ON ops.invoice_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.invoice_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.invoice_facts TO gurine_control_api;
GRANT SELECT ON ops.invoice_facts TO gurine_auditor;
CREATE TABLE ops.invoice_line_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL,
  line_ordinal integer NOT NULL,
  line_kind text NOT NULL,
  sku ops.commercial_sku NOT NULL,
  service_period_start date NOT NULL,
  service_period_end date NOT NULL,
  usage_fact_id uuid,
  usage_fact_digest char(64),
  tariff_version_id uuid,
  tariff_record_digest char(64),
  discount_decision_id uuid,
  discount_record_digest char(64),
  corrects_line_id uuid,
  meter_kind text,
  quantity numeric(24,6) NOT NULL,
  unit_price numeric(24,6) NOT NULL,
  subtotal numeric(24,6) NOT NULL,
  discount_amount numeric(24,6) NOT NULL,
  taxable_amount numeric(24,6) NOT NULL,
  tax_category text NOT NULL,
  tax_rate_basis_points integer NOT NULL,
  tax_exemption_digest char(64),
  tax_policy_digest char(64) NOT NULL,
  tax_amount numeric(24,6) NOT NULL,
  correction_amount numeric(24,6) NOT NULL,
  correction_set_digest char(64) NOT NULL,
  rounding_policy_digest char(64) NOT NULL,
  line_total numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  source_line_digest char(64) NOT NULL,
  line_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_invoice_line_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.invoice_line_facts OWNER TO gurine_migrator;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_ordinal_uq UNIQUE (invoice_id, line_ordinal);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_digest_uq UNIQUE (line_digest);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_invoice_identity_uq UNIQUE (id, invoice_id);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_currency_uq UNIQUE (id, currency);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_revenue_scope_uq UNIQUE (id, invoice_id, sku, currency);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_ordinal_ck CHECK (line_ordinal > 0);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_kind_ck CHECK (line_kind IN ('WORKSPACE_BASE','ACTIVE_CONTRIBUTOR_BLOCK','PROCESSING_CREDIT_OVERAGE','STORAGE_GB_MONTH_OVERAGE','API_RECORD_UNIT_OVERAGE','SLA_ADD_ON','ACCOUNTING_ADJUSTMENT'));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_period_ck CHECK (service_period_end > service_period_start);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_currency_ck CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_meter_kind_ck CHECK (meter_kind IS NULL OR meter_kind IN ('SEAT','AGENT_TOKEN','MODEL_REQUEST','SOURCE_PAGE','STORAGE_BYTE_HOUR','DELIVERY_ATTEMPT','EXPORT_BYTE','API_REQUEST'));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_nonnegative_amounts_ck CHECK (quantity >= 0 AND unit_price >= 0 AND subtotal >= 0 AND discount_amount >= 0 AND taxable_amount >= 0 AND tax_amount >= 0);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_discount_bound_ck CHECK (discount_amount <= subtotal);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_taxable_conservation_ck CHECK (taxable_amount = subtotal - discount_amount);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_total_conservation_ck CHECK (line_total = taxable_amount + tax_amount + correction_amount);
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_metered_reference_ck CHECK (line_kind IN ('WORKSPACE_BASE','SLA_ADD_ON','ACCOUNTING_ADJUSTMENT') OR (usage_fact_id IS NOT NULL AND usage_fact_digest IS NOT NULL AND meter_kind IS NOT NULL));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_fixed_charge_ck CHECK (line_kind NOT IN ('WORKSPACE_BASE','SLA_ADD_ON') OR (usage_fact_id IS NULL AND usage_fact_digest IS NULL AND meter_kind IS NULL AND quantity = 1));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_ordinary_charge_ck CHECK (line_kind = 'ACCOUNTING_ADJUSTMENT' OR (tariff_version_id IS NOT NULL AND corrects_line_id IS NULL AND quantity > 0 AND subtotal = ops.round_half_even_numeric_v1(quantity * unit_price, 6) AND correction_amount = 0 AND line_total >= 0));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_adjustment_ck CHECK (line_kind <> 'ACCOUNTING_ADJUSTMENT' OR (usage_fact_id IS NULL AND usage_fact_digest IS NULL AND tariff_version_id IS NULL AND tariff_record_digest IS NULL AND discount_decision_id IS NULL AND discount_record_digest IS NULL AND corrects_line_id IS NOT NULL AND meter_kind IS NULL AND quantity = 0 AND unit_price = 0 AND subtotal = 0 AND discount_amount = 0 AND taxable_amount = 0 AND tax_amount = 0 AND correction_amount <> 0));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_seat_meter_ck CHECK (line_kind <> 'ACTIVE_CONTRIBUTOR_BLOCK' OR meter_kind = 'SEAT');
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_processing_meter_ck CHECK (line_kind <> 'PROCESSING_CREDIT_OVERAGE' OR meter_kind IN ('AGENT_TOKEN','MODEL_REQUEST','SOURCE_PAGE'));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_storage_meter_ck CHECK (line_kind <> 'STORAGE_GB_MONTH_OVERAGE' OR meter_kind = 'STORAGE_BYTE_HOUR');
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_api_meter_ck CHECK (line_kind <> 'API_RECORD_UNIT_OVERAGE' OR meter_kind = 'API_REQUEST');
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_discount_decision_ck CHECK ((discount_amount = 0 AND discount_decision_id IS NULL AND discount_record_digest IS NULL) OR (discount_amount > 0 AND discount_decision_id IS NOT NULL AND discount_record_digest IS NOT NULL));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_tax_ck CHECK (tax_category IN ('STANDARD','ZERO_RATED','EXEMPT','OUT_OF_SCOPE') AND tax_rate_basis_points BETWEEN 0 AND 10000 AND ((tax_category = 'STANDARD' AND tax_rate_basis_points > 0 AND tax_exemption_digest IS NULL) OR (tax_category IN ('ZERO_RATED','EXEMPT','OUT_OF_SCOPE') AND tax_rate_basis_points = 0 AND tax_exemption_digest IS NOT NULL)) AND tax_amount = ops.round_half_even_numeric_v1(taxable_amount * tax_rate_basis_points::numeric / 10000::numeric, 6));
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_digests_ck CHECK ((usage_fact_digest IS NULL OR usage_fact_digest ~ '^[0-9a-f]{64}$') AND (tariff_record_digest IS NULL OR tariff_record_digest ~ '^[0-9a-f]{64}$') AND (discount_record_digest IS NULL OR discount_record_digest ~ '^[0-9a-f]{64}$') AND (tax_exemption_digest IS NULL OR tax_exemption_digest ~ '^[0-9a-f]{64}$') AND tax_policy_digest ~ '^[0-9a-f]{64}$' AND correction_set_digest ~ '^[0-9a-f]{64}$' AND rounding_policy_digest ~ '^[0-9a-f]{64}$' AND source_line_digest ~ '^[0-9a-f]{64}$' AND line_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX invoice_line_facts_invoice_order_idx ON ops.invoice_line_facts USING btree (invoice_id, line_ordinal, id);
CREATE INDEX invoice_line_facts_usage_idx ON ops.invoice_line_facts USING btree (usage_fact_id, usage_fact_digest, id) WHERE usage_fact_id IS NOT NULL;
CREATE INDEX invoice_line_facts_tariff_idx ON ops.invoice_line_facts USING btree (tariff_version_id, tariff_record_digest, service_period_start, id) WHERE tariff_version_id IS NOT NULL;
CREATE INDEX invoice_line_facts_discount_idx ON ops.invoice_line_facts USING btree (discount_decision_id, discount_record_digest, id) WHERE discount_decision_id IS NOT NULL;
CREATE INDEX invoice_line_facts_corrected_line_idx ON ops.invoice_line_facts USING btree (corrects_line_id, line_ordinal, id) WHERE corrects_line_id IS NOT NULL;
CREATE INDEX invoice_line_facts_invoice_fk_idx ON ops.invoice_line_facts USING btree (invoice_id, currency, id);
CREATE INDEX invoice_line_facts_corrected_line_fk_idx ON ops.invoice_line_facts USING btree (corrects_line_id, invoice_id, id) WHERE corrects_line_id IS NOT NULL;
REVOKE ALL ON ops.invoice_line_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.invoice_line_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.invoice_line_facts TO gurine_control_api;
GRANT SELECT ON ops.invoice_line_facts TO gurine_auditor;
CREATE TABLE ops.invoice_usage_memberships (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_membership_id uuid NOT NULL,
  revision bigint NOT NULL,
  membership_effect ops.invoice_usage_membership_effect NOT NULL,
  supersedes_membership_id uuid,
  predecessor_invoice_id uuid,
  predecessor_membership_digest char(64),
  invoice_id uuid NOT NULL,
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  accounting_timezone text NOT NULL,
  currency char(3) NOT NULL,
  usage_root_fact_id uuid NOT NULL,
  usage_fact_id uuid NOT NULL,
  usage_fact_revision bigint NOT NULL,
  usage_fact_digest char(64) NOT NULL,
  usage_window_receipt_id uuid NOT NULL,
  usage_window_receipt_version bigint NOT NULL,
  usage_window_receipt_digest char(64) NOT NULL,
  meter_kind ops.usage_meter_kind NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  measurement_window_digest char(64) NOT NULL,
  measurement_state ops.usage_measurement_state NOT NULL,
  membership_kind ops.invoice_usage_membership_kind NOT NULL,
  billable_quantity numeric(24,6) NOT NULL,
  included_quantity numeric(24,6) NOT NULL,
  charged_quantity numeric(24,6) NOT NULL,
  billable_unit ops.billable_unit NOT NULL,
  invoice_line_id uuid,
  allocation_policy_digest char(64) NOT NULL,
  membership_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_invoice_usage_memberships_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.invoice_usage_memberships OWNER TO gurine_migrator;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_root_revision_uq UNIQUE (root_membership_id, revision);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_chain_reference_uq UNIQUE (id, root_membership_id, invoice_id, membership_digest);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_root_reference_uq UNIQUE (id, usage_root_fact_id);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_invoice_usage_root_uq UNIQUE (invoice_id, usage_root_fact_id);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_digest_uq UNIQUE (membership_digest);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_revision_ck CHECK (revision > 0 AND usage_fact_revision > 0 AND usage_window_receipt_version > 0);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_chain_shape_ck CHECK ((membership_effect = 'ORIGINAL' AND revision = 1 AND root_membership_id = id AND supersedes_membership_id IS NULL AND predecessor_invoice_id IS NULL AND predecessor_membership_digest IS NULL) OR (membership_effect = 'RESTATEMENT' AND revision > 1 AND root_membership_id <> id AND supersedes_membership_id IS NOT NULL AND predecessor_invoice_id IS NOT NULL AND predecessor_invoice_id <> invoice_id AND predecessor_membership_digest IS NOT NULL));
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_period_ck CHECK (period_start < period_end);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_currency_ck CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_complete_ck CHECK (measurement_state = 'COMPLETE');
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_quantity_ck CHECK (billable_quantity >= 0 AND included_quantity >= 0 AND charged_quantity >= 0 AND billable_quantity = included_quantity + charged_quantity);
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_kind_shape_ck CHECK ((membership_kind = 'ZERO_USAGE' AND billable_quantity = 0 AND included_quantity = 0 AND charged_quantity = 0 AND invoice_line_id IS NULL) OR (membership_kind = 'INCLUDED_ALLOWANCE' AND billable_quantity > 0 AND included_quantity = billable_quantity AND charged_quantity = 0 AND invoice_line_id IS NULL) OR (membership_kind = 'BILLED_OVERAGE' AND billable_quantity > 0 AND charged_quantity > 0 AND invoice_line_id IS NOT NULL));
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_digest_ck CHECK ((predecessor_membership_digest IS NULL OR predecessor_membership_digest ~ '^[0-9a-f]{64}$') AND usage_fact_digest ~ '^[0-9a-f]{64}$' AND usage_window_receipt_digest ~ '^[0-9a-f]{64}$' AND measurement_window_digest ~ '^[0-9a-f]{64}$' AND allocation_policy_digest ~ '^[0-9a-f]{64}$' AND membership_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX invoice_usage_memberships_one_original_uq ON ops.invoice_usage_memberships USING btree (usage_root_fact_id) WHERE membership_effect = 'ORIGINAL';
CREATE UNIQUE INDEX invoice_usage_memberships_one_successor_uq ON ops.invoice_usage_memberships USING btree (supersedes_membership_id) WHERE supersedes_membership_id IS NOT NULL;
CREATE INDEX invoice_usage_memberships_root_fk_idx ON ops.invoice_usage_memberships USING btree (root_membership_id, usage_root_fact_id, id);
CREATE INDEX invoice_usage_memberships_supersedes_fk_idx ON ops.invoice_usage_memberships USING btree (supersedes_membership_id, root_membership_id, predecessor_invoice_id, predecessor_membership_digest, id) WHERE supersedes_membership_id IS NOT NULL;
CREATE INDEX invoice_usage_memberships_root_history_idx ON ops.invoice_usage_memberships USING btree (root_membership_id, revision, id);
CREATE INDEX invoice_usage_memberships_invoice_order_idx ON ops.invoice_usage_memberships USING btree (invoice_id, meter_kind, period_start, period_end, usage_root_fact_id, revision, id);
CREATE INDEX invoice_usage_memberships_invoice_fk_idx ON ops.invoice_usage_memberships USING btree (invoice_id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency, id);
CREATE INDEX invoice_usage_memberships_usage_fk_idx ON ops.invoice_usage_memberships USING btree (usage_fact_id, usage_root_fact_id, usage_fact_revision, usage_fact_digest, id);
CREATE INDEX invoice_usage_memberships_receipt_fk_idx ON ops.invoice_usage_memberships USING btree (usage_window_receipt_id, usage_window_receipt_version, usage_window_receipt_digest, id);
CREATE INDEX invoice_usage_memberships_line_fk_idx ON ops.invoice_usage_memberships USING btree (invoice_line_id, invoice_id, id) WHERE invoice_line_id IS NOT NULL;
REVOKE ALL ON ops.invoice_usage_memberships FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.invoice_usage_memberships TO gurine_workflow_worker;
GRANT SELECT ON ops.invoice_usage_memberships TO gurine_control_api;
GRANT SELECT ON ops.invoice_usage_memberships TO gurine_auditor;
CREATE TABLE ops.revenue_facts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  contract_period_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  invoice_line_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  accounting_timezone text NOT NULL,
  recognition_period_start date NOT NULL,
  recognition_period_end date NOT NULL,
  amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  recognition_policy_version text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  source_record_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  import_receipt_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  recognized_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_revenue_facts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.revenue_facts OWNER TO gurine_migrator;
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_import_receipt_uq UNIQUE (import_receipt_digest);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_source_receipt_uq UNIQUE (source_receipt_digest, source_record_digest);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_scope_uq UNIQUE (id, deployment_id, organization_id, contract_period_id, contract_id, invoice_id, invoice_line_id, sku, accounting_timezone, currency);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_currency_uq UNIQUE (id, currency);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_timezone_shape_ck CHECK (accounting_timezone = btrim(accounting_timezone) AND octet_length(accounting_timezone) BETWEEN 1 AND 255);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_period_ck CHECK (recognition_period_end > recognition_period_start);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_amount_ck CHECK (amount > 0);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_currency_ck CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_policy_version_ck CHECK (recognition_policy_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_time_ck CHECK (recognized_at <= recorded_at);
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_digests_ck CHECK (accounting_policy_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND source_record_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND import_receipt_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX revenue_facts_scope_period_idx ON ops.revenue_facts USING btree (deployment_id, organization_id, recognition_period_start DESC, recognition_period_end DESC, id);
CREATE INDEX revenue_facts_contract_idx ON ops.revenue_facts USING btree (contract_id, recognition_period_start DESC, id);
CREATE INDEX revenue_facts_invoice_idx ON ops.revenue_facts USING btree (invoice_id, invoice_line_id, recognition_period_start, recognition_period_end, id);
CREATE INDEX revenue_facts_line_policy_interval_idx ON ops.revenue_facts USING btree (invoice_line_id, recognition_policy_version, recognition_period_start, recognition_period_end, id);
CREATE INDEX revenue_facts_contract_period_fk_idx ON ops.revenue_facts USING btree (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone, id);
CREATE INDEX revenue_facts_invoice_fk_idx ON ops.revenue_facts USING btree (invoice_id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency, id);
CREATE INDEX revenue_facts_invoice_line_fk_idx ON ops.revenue_facts USING btree (invoice_line_id, invoice_id, sku, currency, id);
REVOKE ALL ON ops.revenue_facts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.revenue_facts TO gurine_workflow_worker;
GRANT SELECT ON ops.revenue_facts TO gurine_control_api;
GRANT SELECT ON ops.revenue_facts TO gurine_auditor;
CREATE TABLE ops.funding_concentration_snapshots (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  snapshot_batch_id uuid NOT NULL,
  snapshot_version bigint NOT NULL,
  row_kind ops.funding_snapshot_row_kind NOT NULL,
  ordinal integer NOT NULL,
  header_id uuid,
  fiscal_year integer NOT NULL,
  as_of timestamptz NOT NULL,
  reporting_currency char(3) NOT NULL,
  prior_header_id uuid,
  prior_snapshot_digest char(64),
  funding_policy_version text,
  funding_policy_digest char(64),
  fx_snapshot_digest char(64),
  denominator_amount numeric(24,6),
  denominator_state ops.funding_denominator_state,
  denominator_unknown_reason ops.funding_denominator_unknown_reason,
  denominator_approval_digest char(64),
  denominator_approver_set_digest char(64),
  denominator_approved_at timestamptz,
  denominator_approval_expires_at timestamptz,
  entry_count integer,
  entry_set_digest char(64),
  source_set_digest char(64),
  snapshot_digest char(64),
  import_receipt_digest char(64),
  audit_event_id uuid,
  outbox_id uuid,
  imported_at timestamptz,
  counterparty_group_id uuid,
  counterparty_group_digest char(64),
  grouping_state ops.funding_grouping_state,
  grouping_dispute_reason ops.funding_grouping_dispute_reason,
  grouping_evidence_digest char(64),
  member_supplier_ids uuid[],
  member_supplier_identity_digests char(64)[],
  funding_source_kind ops.funding_source_kind,
  recognized_revenue numeric(24,6),
  binding_committed_revenue numeric(24,6),
  numerator numeric(24,6),
  concentration_share numeric(24,6),
  concentration_band editorial.funding_concentration_band,
  concentration_unknown_reason ops.funding_concentration_unknown_reason,
  government_related boolean,
  political_party_related boolean,
  procurement_supplier_related boolean,
  investigated_subject_related boolean,
  related_party boolean,
  related_case_ids uuid[],
  recognized_revenue_fact_ids uuid[],
  recognized_revenue_fact_digests char(64)[],
  recognized_revenue_fact_amounts numeric(24,6)[],
  binding_contract_period_ids uuid[],
  binding_contract_period_digests char(64)[],
  binding_contract_period_amounts numeric(24,6)[],
  external_funding_source_receipt_ids uuid[],
  external_funding_source_receipt_digests char(64)[],
  external_funding_source_signature_digests char(64)[],
  external_funding_source_kinds ops.funding_source_kind[],
  external_funding_amount_bases ops.funding_amount_basis[],
  external_funding_source_amounts numeric(24,6)[],
  entry_source_set_digest char(64),
  independent_review_requirement_digest char(64),
  entry_digest char(64),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_funding_concentration_snapshots_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.funding_concentration_snapshots OWNER TO gurine_migrator;
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_batch_ordinal_uq UNIQUE (snapshot_batch_id, ordinal);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_id_batch_uq UNIQUE (id, snapshot_batch_id);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_header_binding_uq UNIQUE (id, snapshot_batch_id, snapshot_digest);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_entry_binding_uq UNIQUE (id, snapshot_batch_id, entry_digest);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_group_once_uq UNIQUE (header_id, counterparty_group_id);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_common_check CHECK (snapshot_version > 0 AND ordinal >= 0 AND fiscal_year BETWEEN 1 AND 9999 AND reporting_currency ~ '^[A-Z]{3}$' AND as_of <= created_at + interval '5 seconds');
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_row_shape_check CHECK ((row_kind = 'SNAPSHOT_HEADER' AND ordinal = 0 AND header_id IS NULL
 AND funding_policy_version IS NOT NULL AND funding_policy_digest IS NOT NULL
 AND fx_snapshot_digest IS NOT NULL AND denominator_state IS NOT NULL
 AND entry_count IS NOT NULL AND entry_set_digest IS NOT NULL
 AND source_set_digest IS NOT NULL AND snapshot_digest IS NOT NULL
 AND import_receipt_digest IS NOT NULL AND audit_event_id IS NOT NULL
 AND outbox_id IS NOT NULL AND imported_at IS NOT NULL
 AND counterparty_group_id IS NULL AND counterparty_group_digest IS NULL
 AND grouping_state IS NULL AND grouping_dispute_reason IS NULL
 AND grouping_evidence_digest IS NULL AND member_supplier_ids IS NULL
 AND member_supplier_identity_digests IS NULL AND funding_source_kind IS NULL
 AND recognized_revenue IS NULL AND binding_committed_revenue IS NULL
 AND numerator IS NULL AND concentration_share IS NULL
 AND concentration_band IS NULL AND concentration_unknown_reason IS NULL
 AND government_related IS NULL AND political_party_related IS NULL
 AND procurement_supplier_related IS NULL AND investigated_subject_related IS NULL
 AND related_party IS NULL
 AND related_case_ids IS NULL AND recognized_revenue_fact_ids IS NULL
 AND recognized_revenue_fact_digests IS NULL AND recognized_revenue_fact_amounts IS NULL
 AND binding_contract_period_ids IS NULL AND binding_contract_period_digests IS NULL
 AND binding_contract_period_amounts IS NULL
 AND external_funding_source_receipt_ids IS NULL
 AND external_funding_source_receipt_digests IS NULL
 AND external_funding_source_signature_digests IS NULL
 AND external_funding_source_kinds IS NULL AND external_funding_amount_bases IS NULL
 AND external_funding_source_amounts IS NULL AND entry_source_set_digest IS NULL
 AND independent_review_requirement_digest IS NULL AND entry_digest IS NULL)
OR (row_kind = 'COUNTERPARTY_ENTRY' AND ordinal > 0 AND header_id IS NOT NULL
 AND prior_header_id IS NULL AND prior_snapshot_digest IS NULL
 AND funding_policy_version IS NULL AND funding_policy_digest IS NULL
 AND fx_snapshot_digest IS NULL AND denominator_amount IS NULL
 AND denominator_state IS NULL AND denominator_unknown_reason IS NULL
 AND denominator_approval_digest IS NULL AND denominator_approver_set_digest IS NULL
 AND denominator_approved_at IS NULL AND denominator_approval_expires_at IS NULL
 AND entry_count IS NULL AND entry_set_digest IS NULL AND source_set_digest IS NULL
 AND snapshot_digest IS NULL AND import_receipt_digest IS NULL
 AND audit_event_id IS NULL AND outbox_id IS NULL AND imported_at IS NULL
 AND counterparty_group_id IS NOT NULL AND counterparty_group_digest IS NOT NULL
 AND grouping_state IS NOT NULL AND grouping_evidence_digest IS NOT NULL
 AND member_supplier_ids IS NOT NULL AND member_supplier_identity_digests IS NOT NULL
 AND funding_source_kind IS NOT NULL AND recognized_revenue IS NOT NULL
 AND binding_committed_revenue IS NOT NULL AND numerator IS NOT NULL
 AND concentration_band IS NOT NULL AND government_related IS NOT NULL
 AND political_party_related IS NOT NULL AND procurement_supplier_related IS NOT NULL
 AND investigated_subject_related IS NOT NULL AND related_party IS NOT NULL
 AND related_case_ids IS NOT NULL
 AND recognized_revenue_fact_ids IS NOT NULL
 AND recognized_revenue_fact_digests IS NOT NULL
 AND recognized_revenue_fact_amounts IS NOT NULL
 AND binding_contract_period_ids IS NOT NULL
 AND binding_contract_period_digests IS NOT NULL
 AND binding_contract_period_amounts IS NOT NULL
 AND external_funding_source_receipt_ids IS NOT NULL
 AND external_funding_source_receipt_digests IS NOT NULL
 AND external_funding_source_signature_digests IS NOT NULL
 AND external_funding_source_kinds IS NOT NULL
 AND external_funding_amount_bases IS NOT NULL
 AND external_funding_source_amounts IS NOT NULL
 AND entry_source_set_digest IS NOT NULL
 AND independent_review_requirement_digest IS NOT NULL AND entry_digest IS NOT NULL));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_header_chain_check CHECK (row_kind <> 'SNAPSHOT_HEADER' OR ((snapshot_version = 1 AND prior_header_id IS NULL AND prior_snapshot_digest IS NULL)
 OR (snapshot_version > 1 AND prior_header_id IS NOT NULL
  AND prior_snapshot_digest IS NOT NULL AND prior_snapshot_digest ~ '^[0-9a-f]{64}$')));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_denominator_check CHECK (row_kind <> 'SNAPSHOT_HEADER' OR (denominator_state = 'APPROVED' AND denominator_amount IS NOT NULL AND denominator_amount > 0
 AND denominator_unknown_reason IS NULL
 AND denominator_approval_digest IS NOT NULL AND denominator_approval_digest ~ '^[0-9a-f]{64}$'
 AND denominator_approver_set_digest IS NOT NULL AND denominator_approver_set_digest ~ '^[0-9a-f]{64}$'
 AND denominator_approved_at IS NOT NULL
 AND denominator_approved_at <= as_of
 AND denominator_approval_expires_at IS NOT NULL
 AND denominator_approval_expires_at > denominator_approved_at
 AND as_of < denominator_approval_expires_at)
OR (denominator_state = 'UNKNOWN' AND denominator_unknown_reason IS NOT NULL AND (
   (denominator_unknown_reason = 'MISSING' AND denominator_amount IS NULL
    AND denominator_approval_digest IS NULL AND denominator_approver_set_digest IS NULL
    AND denominator_approved_at IS NULL AND denominator_approval_expires_at IS NULL)
   OR (denominator_unknown_reason = 'ZERO' AND denominator_amount IS NOT NULL AND denominator_amount = 0
    AND denominator_approval_digest IS NULL AND denominator_approver_set_digest IS NULL
    AND denominator_approved_at IS NULL AND denominator_approval_expires_at IS NULL)
   OR (denominator_unknown_reason = 'APPROVAL_MISSING' AND denominator_amount IS NOT NULL AND denominator_amount > 0
    AND denominator_approval_digest IS NULL AND denominator_approver_set_digest IS NULL
    AND denominator_approved_at IS NULL AND denominator_approval_expires_at IS NULL)
   OR (denominator_unknown_reason = 'APPROVAL_STALE'
    AND denominator_amount IS NOT NULL AND denominator_amount > 0
    AND denominator_approval_digest IS NOT NULL AND denominator_approval_digest ~ '^[0-9a-f]{64}$'
    AND denominator_approver_set_digest IS NOT NULL AND denominator_approver_set_digest ~ '^[0-9a-f]{64}$'
    AND denominator_approved_at IS NOT NULL
    AND denominator_approved_at <= as_of
    AND denominator_approval_expires_at IS NOT NULL
    AND denominator_approval_expires_at > denominator_approved_at
    AND as_of >= denominator_approval_expires_at))));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_header_count_check CHECK (row_kind <> 'SNAPSHOT_HEADER' OR entry_count >= 0);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_header_time_check CHECK (row_kind <> 'SNAPSHOT_HEADER' OR (as_of <= imported_at AND imported_at <= created_at + interval '5 seconds'));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_policy_check CHECK (row_kind <> 'SNAPSHOT_HEADER' OR (funding_policy_version IS NOT NULL AND length(btrim(funding_policy_version)) BETWEEN 1 AND 128 AND funding_policy_digest IS NOT NULL AND funding_policy_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_amount_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (recognized_revenue >= 0 AND binding_committed_revenue >= 0 AND numerator = recognized_revenue + binding_committed_revenue));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_member_pair_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (cardinality(member_supplier_ids) = cardinality(member_supplier_identity_digests) AND cardinality(member_supplier_ids) <= 10000));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_source_fact_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (cardinality(recognized_revenue_fact_ids) = cardinality(recognized_revenue_fact_digests)
 AND cardinality(recognized_revenue_fact_ids) = cardinality(recognized_revenue_fact_amounts)
 AND cardinality(binding_contract_period_ids) = cardinality(binding_contract_period_digests)
 AND cardinality(binding_contract_period_ids) = cardinality(binding_contract_period_amounts)
 AND cardinality(external_funding_source_receipt_ids) = cardinality(external_funding_source_receipt_digests)
 AND cardinality(external_funding_source_receipt_ids) = cardinality(external_funding_source_signature_digests)
 AND cardinality(external_funding_source_receipt_ids) = cardinality(external_funding_source_kinds)
 AND cardinality(external_funding_source_receipt_ids) = cardinality(external_funding_amount_bases)
 AND cardinality(external_funding_source_receipt_ids) = cardinality(external_funding_source_amounts)
 AND cardinality(recognized_revenue_fact_ids) + cardinality(binding_contract_period_ids)
   + cardinality(external_funding_source_receipt_ids) BETWEEN 1 AND 10000));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_entry_source_digest_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (entry_source_set_digest IS NOT NULL AND entry_source_set_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_related_case_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR cardinality(related_case_ids) <= 10000);
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_grouping_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (grouping_state = 'RESOLVED' AND grouping_dispute_reason IS NULL) OR (grouping_state = 'DISPUTED' AND grouping_dispute_reason IS NOT NULL
 AND concentration_share IS NULL AND concentration_band = 'UNKNOWN'
 AND concentration_unknown_reason IS NOT NULL
 AND concentration_unknown_reason = 'GROUPING_DISPUTED'));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_concentration_check CHECK (row_kind <> 'COUNTERPARTY_ENTRY' OR (concentration_band = 'UNKNOWN' AND concentration_share IS NULL
 AND concentration_unknown_reason IS NOT NULL)
OR (concentration_band IN ('LE_5_PERCENT','GT_5_TO_15_PERCENT','GT_15_TO_25_PERCENT','GT_25_PERCENT')
 AND concentration_unknown_reason IS NULL
 AND concentration_share IS NOT NULL AND concentration_share >= 0));
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_scalar_digest_check CHECK ((prior_snapshot_digest IS NULL OR prior_snapshot_digest ~ '^[0-9a-f]{64}$') AND (funding_policy_digest IS NULL OR funding_policy_digest ~ '^[0-9a-f]{64}$') AND (fx_snapshot_digest IS NULL OR fx_snapshot_digest ~ '^[0-9a-f]{64}$') AND (entry_set_digest IS NULL OR entry_set_digest ~ '^[0-9a-f]{64}$') AND (source_set_digest IS NULL OR source_set_digest ~ '^[0-9a-f]{64}$') AND (snapshot_digest IS NULL OR snapshot_digest ~ '^[0-9a-f]{64}$') AND (import_receipt_digest IS NULL OR import_receipt_digest ~ '^[0-9a-f]{64}$') AND (counterparty_group_digest IS NULL OR counterparty_group_digest ~ '^[0-9a-f]{64}$') AND (grouping_evidence_digest IS NULL OR grouping_evidence_digest ~ '^[0-9a-f]{64}$') AND (entry_source_set_digest IS NULL OR entry_source_set_digest ~ '^[0-9a-f]{64}$') AND (independent_review_requirement_digest IS NULL OR independent_review_requirement_digest ~ '^[0-9a-f]{64}$') AND (entry_digest IS NULL OR entry_digest ~ '^[0-9a-f]{64}$'));
CREATE UNIQUE INDEX funding_snapshot_header_batch_uq ON ops.funding_concentration_snapshots USING btree (snapshot_batch_id) WHERE row_kind = 'SNAPSHOT_HEADER';
CREATE UNIQUE INDEX funding_snapshot_fiscal_version_uq ON ops.funding_concentration_snapshots USING btree (fiscal_year, snapshot_version) WHERE row_kind = 'SNAPSHOT_HEADER';
CREATE UNIQUE INDEX funding_snapshot_digest_uq ON ops.funding_concentration_snapshots USING btree (snapshot_digest) WHERE row_kind = 'SNAPSHOT_HEADER';
CREATE INDEX funding_snapshot_latest_idx ON ops.funding_concentration_snapshots USING btree (fiscal_year, as_of DESC, snapshot_version DESC, id DESC) WHERE row_kind = 'SNAPSHOT_HEADER';
CREATE INDEX funding_snapshot_entry_order_idx ON ops.funding_concentration_snapshots USING btree (header_id, ordinal, id) WHERE row_kind = 'COUNTERPARTY_ENTRY';
CREATE INDEX funding_snapshot_group_history_idx ON ops.funding_concentration_snapshots USING btree (counterparty_group_digest, fiscal_year DESC, as_of DESC, id DESC) WHERE row_kind = 'COUNTERPARTY_ENTRY';
CREATE INDEX funding_snapshot_related_cases_idx ON ops.funding_concentration_snapshots USING gin (related_case_ids) WHERE row_kind = 'COUNTERPARTY_ENTRY' AND cardinality(related_case_ids) > 0;
CREATE INDEX funding_snapshot_prior_header_fk_idx ON ops.funding_concentration_snapshots USING btree (prior_header_id, id) WHERE prior_header_id IS NOT NULL;
CREATE INDEX funding_snapshot_audit_fk_idx ON ops.funding_concentration_snapshots USING btree (audit_event_id, id) WHERE audit_event_id IS NOT NULL;
CREATE INDEX funding_snapshot_outbox_fk_idx ON ops.funding_concentration_snapshots USING btree (outbox_id, id) WHERE outbox_id IS NOT NULL;
REVOKE ALL ON ops.funding_concentration_snapshots FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.funding_concentration_snapshots TO gurine_workflow_worker;
GRANT SELECT ON ops.funding_concentration_snapshots TO gurine_control_api;
GRANT SELECT ON ops.funding_concentration_snapshots TO gurine_auditor;
CREATE TABLE editorial.funding_disclosure_revisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  disclosure_id uuid NOT NULL,
  revision bigint NOT NULL,
  prior_revision_id uuid,
  prior_disclosure_id uuid,
  prior_revision bigint,
  prior_revision_digest char(64),
  fiscal_year integer NOT NULL,
  fiscal_quarter smallint NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  snapshot_header_id uuid NOT NULL,
  snapshot_batch_id uuid NOT NULL,
  snapshot_digest char(64) NOT NULL,
  funding_policy_version text NOT NULL,
  funding_policy_digest char(64) NOT NULL,
  naming_threshold_amount numeric(24,6) NOT NULL,
  amount_band_lower numeric(24,6) NOT NULL,
  amount_band_upper numeric(24,6),
  reporting_currency char(3) NOT NULL,
  concentration_band editorial.funding_concentration_band NOT NULL,
  quorum_class editorial.funding_quorum_class NOT NULL,
  requires_oversight_review boolean NOT NULL,
  requires_board_approval boolean NOT NULL,
  requires_enhanced_public_disclosure boolean NOT NULL,
  has_related_party_gate boolean NOT NULL,
  conditional_gate_set_digest char(64) NOT NULL,
  unknown_reason editorial.funding_disclosure_unknown_reason,
  public_caveat_text text,
  purpose text NOT NULL,
  conflict_summary text NOT NULL,
  policy_request_total integer NOT NULL,
  policy_request_accepted integer NOT NULL,
  policy_request_partially_accepted integer NOT NULL,
  policy_request_rejected integer NOT NULL,
  policy_request_withdrawn integer NOT NULL,
  policy_request_pending integer NOT NULL,
  policy_request_outcome_digest char(64) NOT NULL,
  source_link_set_digest char(64) NOT NULL,
  entry_count integer NOT NULL,
  entry_set_digest char(64) NOT NULL,
  policy_snapshot_digest char(64) NOT NULL,
  conflict_snapshot_id uuid NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  quorum_snapshot_digest char(64) NOT NULL,
  public_content_digest char(64) NOT NULL,
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  execution_id uuid NOT NULL,
  execution_generation bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  execution_digest char(64) NOT NULL,
  preparer_decision_id uuid NOT NULL,
  publisher_decision_id uuid NOT NULL,
  oversight_decision_id uuid,
  board_decision_id uuid,
  independent_case_review_decision_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  independent_case_review_set_digest char(64) NOT NULL,
  decision_receipt_set_digest char(64) NOT NULL,
  prepared_by_user_id uuid NOT NULL,
  published_by_user_id uuid NOT NULL,
  oversight_reviewer_user_id uuid,
  board_approver_user_id uuid,
  effective_at timestamptz NOT NULL,
  published_at timestamptz NOT NULL,
  execution_receipt_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  revision_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT editorial_funding_disclosure_revisions_pkey PRIMARY KEY (id)
);
ALTER TABLE editorial.funding_disclosure_revisions OWNER TO gurine_migrator;
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_series_revision_uq UNIQUE (disclosure_id, revision);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_entry_parent_identity_uq UNIQUE (id, disclosure_id, revision);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_chain_reference_uq UNIQUE (id, disclosure_id, revision, revision_digest);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_quarter_revision_uq UNIQUE (fiscal_year, fiscal_quarter, revision);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_execution_uq UNIQUE (execution_id, execution_generation);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_revision_digest_uq UNIQUE (revision_digest);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_public_source_uq UNIQUE (id, revision_digest);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_entry_parent_uq UNIQUE (id, disclosure_id, revision, entry_set_digest);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_identity_check CHECK (revision > 0 AND proposal_version > 0 AND execution_generation > 0 AND fiscal_year BETWEEN 1 AND 9999 AND fiscal_quarter BETWEEN 1 AND 4);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_period_check CHECK (period_start < period_end AND period_end <= published_at::date);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_prior_check CHECK ((revision = 1 AND prior_revision_id IS NULL AND prior_disclosure_id IS NULL
 AND prior_revision IS NULL AND prior_revision_digest IS NULL)
OR (revision > 1 AND prior_revision_id IS NOT NULL AND prior_disclosure_id IS NOT NULL
 AND prior_disclosure_id = disclosure_id AND prior_revision IS NOT NULL
 AND prior_revision = revision - 1 AND prior_revision_digest IS NOT NULL
 AND prior_revision_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_amount_band_check CHECK (naming_threshold_amount >= 0 AND amount_band_lower >= 0 AND (amount_band_upper IS NULL OR amount_band_upper > amount_band_lower) AND reporting_currency ~ '^[A-Z]{3}$');
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_policy_check CHECK (length(btrim(funding_policy_version)) BETWEEN 1 AND 128 AND funding_policy_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_unknown_check CHECK ((concentration_band = 'UNKNOWN' AND unknown_reason IS NOT NULL
 AND public_caveat_text IS NOT NULL AND length(btrim(public_caveat_text)) BETWEEN 1 AND 2000)
OR (concentration_band <> 'UNKNOWN' AND unknown_reason IS NULL AND public_caveat_text IS NULL));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_text_check CHECK (length(btrim(purpose)) BETWEEN 1 AND 4000 AND length(btrim(conflict_summary)) BETWEEN 1 AND 8000);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_policy_count_check CHECK (policy_request_total >= 0 AND policy_request_accepted >= 0 AND policy_request_partially_accepted >= 0 AND policy_request_rejected >= 0 AND policy_request_withdrawn >= 0 AND policy_request_pending >= 0 AND policy_request_total = policy_request_accepted + policy_request_partially_accepted
  + policy_request_rejected + policy_request_withdrawn + policy_request_pending);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_entry_count_check CHECK (entry_count >= 0);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_base_sod_check CHECK (preparer_decision_id <> publisher_decision_id AND prepared_by_user_id <> published_by_user_id);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_conditional_pair_check CHECK ((oversight_decision_id IS NULL) = (oversight_reviewer_user_id IS NULL) AND (board_decision_id IS NULL) = (board_approver_user_id IS NULL));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_actor_pairwise_check CHECK ((oversight_reviewer_user_id IS NULL OR (oversight_reviewer_user_id <> prepared_by_user_id AND oversight_reviewer_user_id <> published_by_user_id)) AND (board_approver_user_id IS NULL OR (board_approver_user_id <> prepared_by_user_id AND board_approver_user_id <> published_by_user_id AND (oversight_reviewer_user_id IS NULL OR board_approver_user_id <> oversight_reviewer_user_id))) AND (oversight_decision_id IS NULL OR (oversight_decision_id <> preparer_decision_id AND oversight_decision_id <> publisher_decision_id)) AND (board_decision_id IS NULL OR (board_decision_id <> preparer_decision_id AND board_decision_id <> publisher_decision_id AND (oversight_decision_id IS NULL OR board_decision_id <> oversight_decision_id))));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_conditional_gate_shape_check CHECK ((requires_board_approval = false OR requires_oversight_review = true) AND (requires_enhanced_public_disclosure = false OR requires_board_approval = true) AND ((requires_oversight_review AND oversight_decision_id IS NOT NULL) OR (NOT requires_oversight_review AND oversight_decision_id IS NULL)) AND ((requires_board_approval AND board_decision_id IS NOT NULL) OR (NOT requires_board_approval AND board_decision_id IS NULL)));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_threshold_approval_check CHECK ((concentration_band IN ('LE_5_PERCENT','GT_5_TO_15_PERCENT')
 AND requires_oversight_review = false AND requires_board_approval = false
 AND requires_enhanced_public_disclosure = false)
OR (concentration_band = 'GT_15_TO_25_PERCENT'
 AND requires_oversight_review = true AND requires_board_approval = false
 AND requires_enhanced_public_disclosure = false)
OR (concentration_band IN ('GT_25_PERCENT','UNKNOWN')
 AND requires_oversight_review = true AND requires_board_approval = true
 AND requires_enhanced_public_disclosure = true));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_quorum_class_check CHECK ((NOT requires_oversight_review AND NOT requires_board_approval
 AND ((NOT has_related_party_gate AND quorum_class = 'STANDARD')
   OR (has_related_party_gate AND quorum_class = 'RELATED_PARTY')))
OR (requires_oversight_review AND NOT requires_board_approval
 AND ((NOT has_related_party_gate AND quorum_class = 'OVERSIGHT')
   OR (has_related_party_gate AND quorum_class = 'OVERSIGHT_RELATED_PARTY')))
OR (requires_oversight_review AND requires_board_approval
 AND ((NOT has_related_party_gate AND quorum_class = 'BOARD')
   OR (has_related_party_gate AND quorum_class = 'BOARD_RELATED_PARTY'))));
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_case_review_array_check CHECK (cardinality(independent_case_review_decision_ids) <= 10000);
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_digest_check CHECK (snapshot_digest ~ '^[0-9a-f]{64}$' AND funding_policy_digest ~ '^[0-9a-f]{64}$' AND policy_request_outcome_digest ~ '^[0-9a-f]{64}$' AND source_link_set_digest ~ '^[0-9a-f]{64}$' AND entry_set_digest ~ '^[0-9a-f]{64}$' AND policy_snapshot_digest ~ '^[0-9a-f]{64}$' AND conflict_snapshot_digest ~ '^[0-9a-f]{64}$' AND quorum_snapshot_digest ~ '^[0-9a-f]{64}$' AND conditional_gate_set_digest ~ '^[0-9a-f]{64}$' AND public_content_digest ~ '^[0-9a-f]{64}$' AND approval_digest ~ '^[0-9a-f]{64}$' AND execution_digest ~ '^[0-9a-f]{64}$' AND independent_case_review_set_digest ~ '^[0-9a-f]{64}$' AND decision_receipt_set_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$' AND revision_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_time_check CHECK (effective_at <= published_at AND published_at <= created_at + interval '5 seconds');
CREATE INDEX funding_disclosure_latest_idx ON editorial.funding_disclosure_revisions USING btree (fiscal_year DESC, fiscal_quarter DESC, effective_at DESC, revision DESC, id DESC);
CREATE INDEX funding_disclosure_history_idx ON editorial.funding_disclosure_revisions USING btree (disclosure_id, revision ASC, id ASC);
CREATE INDEX funding_disclosure_snapshot_idx ON editorial.funding_disclosure_revisions USING btree (snapshot_batch_id, snapshot_digest, revision DESC, id DESC);
CREATE INDEX funding_disclosure_effective_idx ON editorial.funding_disclosure_revisions USING btree (effective_at DESC, id DESC);
CREATE INDEX funding_disclosure_conditional_gate_idx ON editorial.funding_disclosure_revisions USING btree (requires_board_approval, requires_oversight_review, has_related_party_gate, effective_at DESC, id DESC);
CREATE INDEX funding_disclosure_snapshot_fk_idx ON editorial.funding_disclosure_revisions USING btree (snapshot_header_id, snapshot_batch_id, snapshot_digest, id);
CREATE INDEX funding_disclosure_prior_fk_idx ON editorial.funding_disclosure_revisions USING btree (prior_revision_id, prior_disclosure_id, prior_revision, prior_revision_digest, id) WHERE prior_revision_id IS NOT NULL;
CREATE INDEX funding_disclosure_proposal_fk_idx ON editorial.funding_disclosure_revisions USING btree (proposal_id, proposal_version, approval_digest, id);
CREATE INDEX funding_disclosure_preparer_decision_fk_idx ON editorial.funding_disclosure_revisions USING btree (preparer_decision_id, id);
CREATE INDEX funding_disclosure_publisher_decision_fk_idx ON editorial.funding_disclosure_revisions USING btree (publisher_decision_id, id);
CREATE INDEX funding_disclosure_oversight_decision_fk_idx ON editorial.funding_disclosure_revisions USING btree (oversight_decision_id, id) WHERE oversight_decision_id IS NOT NULL;
CREATE INDEX funding_disclosure_board_decision_fk_idx ON editorial.funding_disclosure_revisions USING btree (board_decision_id, id) WHERE board_decision_id IS NOT NULL;
CREATE INDEX funding_disclosure_preparer_user_fk_idx ON editorial.funding_disclosure_revisions USING btree (prepared_by_user_id, id);
CREATE INDEX funding_disclosure_publisher_user_fk_idx ON editorial.funding_disclosure_revisions USING btree (published_by_user_id, id);
CREATE INDEX funding_disclosure_oversight_user_fk_idx ON editorial.funding_disclosure_revisions USING btree (oversight_reviewer_user_id, id) WHERE oversight_reviewer_user_id IS NOT NULL;
CREATE INDEX funding_disclosure_board_user_fk_idx ON editorial.funding_disclosure_revisions USING btree (board_approver_user_id, id) WHERE board_approver_user_id IS NOT NULL;
CREATE INDEX funding_disclosure_conflict_snapshot_fk_idx ON editorial.funding_disclosure_revisions USING btree (conflict_snapshot_id, id);
CREATE INDEX funding_disclosure_execution_receipt_fk_idx ON editorial.funding_disclosure_revisions USING btree (execution_receipt_id, id);
CREATE INDEX funding_disclosure_audit_fk_idx ON editorial.funding_disclosure_revisions USING btree (audit_event_id, id);
CREATE INDEX funding_disclosure_outbox_fk_idx ON editorial.funding_disclosure_revisions USING btree (outbox_id, id);
REVOKE ALL ON editorial.funding_disclosure_revisions FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON editorial.funding_disclosure_revisions TO gurine_workflow_worker;
GRANT SELECT ON editorial.funding_disclosure_revisions TO gurine_control_api;
GRANT SELECT ON editorial.funding_disclosure_revisions TO gurine_auditor;
CREATE TABLE editorial.funding_disclosure_entries (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  revision_id uuid NOT NULL,
  disclosure_id uuid NOT NULL,
  revision bigint NOT NULL,
  ordinal integer NOT NULL,
  snapshot_batch_id uuid NOT NULL,
  snapshot_digest char(64) NOT NULL,
  source_snapshot_entry_ids uuid[] NOT NULL,
  source_snapshot_entry_digests char(64)[] NOT NULL,
  source_snapshot_entry_set_digest char(64) NOT NULL,
  source_counterparty_group_set_digest char(64) NOT NULL,
  identity_disclosure_mode editorial.funding_identity_disclosure_mode NOT NULL,
  public_display_name text,
  withholding_reason editorial.funding_identity_withholding_reason,
  withholding_public_explanation text,
  counterparty_category text NOT NULL,
  funding_source_kind ops.funding_source_kind NOT NULL,
  amount_band_lower numeric(24,6) NOT NULL,
  amount_band_upper numeric(24,6),
  reporting_currency char(3) NOT NULL,
  concentration_band editorial.funding_concentration_band NOT NULL,
  denominator_unknown_reason ops.funding_denominator_unknown_reason,
  grouping_dispute_reason ops.funding_grouping_dispute_reason,
  concentration_unknown_reason ops.funding_concentration_unknown_reason,
  public_caveat_text text,
  purpose text NOT NULL,
  conflict_disclosure text NOT NULL,
  mitigation_summary text NOT NULL,
  government_related boolean NOT NULL,
  political_party_related boolean NOT NULL,
  procurement_supplier_related boolean NOT NULL,
  investigated_subject_related boolean NOT NULL,
  related_party boolean NOT NULL,
  related_case_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  independent_review_required boolean NOT NULL,
  independent_review_decision_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  independent_review_set_digest char(64) NOT NULL,
  evidence_ids uuid[] NOT NULL,
  source_link_set_digest char(64) NOT NULL,
  entry_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT editorial_funding_disclosure_entries_pkey PRIMARY KEY (id)
);
ALTER TABLE editorial.funding_disclosure_entries OWNER TO gurine_migrator;
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_ordinal_uq UNIQUE (revision_id, ordinal);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_digest_uq UNIQUE (revision_id, entry_digest);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_source_set_uq UNIQUE (revision_id, source_snapshot_entry_set_digest);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_identity_check CHECK (revision > 0 AND ordinal > 0);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_source_pair_check CHECK (cardinality(source_snapshot_entry_ids) = cardinality(source_snapshot_entry_digests) AND cardinality(source_snapshot_entry_ids) BETWEEN 1 AND 10000);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_name_check CHECK ((identity_disclosure_mode = 'NAMED' AND cardinality(source_snapshot_entry_ids) = 1
 AND public_display_name IS NOT NULL
 AND length(btrim(public_display_name)) BETWEEN 1 AND 500
 AND withholding_reason IS NULL AND withholding_public_explanation IS NULL)
OR (identity_disclosure_mode IN ('CATEGORY_ONLY','WITHHELD_LEGAL')
 AND public_display_name IS NULL AND withholding_reason IS NOT NULL
 AND withholding_public_explanation IS NOT NULL
 AND length(btrim(withholding_public_explanation)) BETWEEN 1 AND 2000));
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_withholding_check CHECK (identity_disclosure_mode <> 'WITHHELD_LEGAL' OR (withholding_reason IS NOT NULL
 AND withholding_reason IN ('LEGAL_RESTRICTION','PRIVACY_RESTRICTION','REVIEWED_CONFIDENTIALITY_DUTY')));
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_text_check CHECK (length(btrim(counterparty_category)) BETWEEN 1 AND 200 AND length(btrim(purpose)) BETWEEN 1 AND 4000 AND length(btrim(conflict_disclosure)) BETWEEN 1 AND 8000 AND length(btrim(mitigation_summary)) BETWEEN 1 AND 8000);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_amount_check CHECK (amount_band_lower >= 0 AND (amount_band_upper IS NULL OR amount_band_upper > amount_band_lower) AND reporting_currency ~ '^[A-Z]{3}$');
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_unknown_check CHECK ((concentration_band = 'UNKNOWN' AND concentration_unknown_reason IS NOT NULL
 AND public_caveat_text IS NOT NULL AND length(btrim(public_caveat_text)) BETWEEN 1 AND 2000
 AND ((concentration_unknown_reason = 'DENOMINATOR_UNKNOWN'
   AND denominator_unknown_reason IS NOT NULL AND grouping_dispute_reason IS NULL)
  OR (concentration_unknown_reason = 'GROUPING_DISPUTED'
   AND grouping_dispute_reason IS NOT NULL)))
OR (concentration_band <> 'UNKNOWN' AND denominator_unknown_reason IS NULL
 AND grouping_dispute_reason IS NULL AND concentration_unknown_reason IS NULL
 AND public_caveat_text IS NULL));
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_case_check CHECK (cardinality(related_case_ids) <= 10000 AND cardinality(evidence_ids) BETWEEN 1 AND 10000);
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_independence_check CHECK ((independent_review_required AND cardinality(related_case_ids) > 0
 AND cardinality(independent_review_decision_ids) = cardinality(related_case_ids))
OR (NOT independent_review_required AND cardinality(independent_review_decision_ids) = 0));
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_digest_check CHECK (snapshot_digest ~ '^[0-9a-f]{64}$' AND source_snapshot_entry_set_digest ~ '^[0-9a-f]{64}$' AND source_counterparty_group_set_digest ~ '^[0-9a-f]{64}$' AND independent_review_set_digest ~ '^[0-9a-f]{64}$' AND source_link_set_digest ~ '^[0-9a-f]{64}$' AND entry_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX funding_disclosure_entry_order_idx ON editorial.funding_disclosure_entries USING btree (revision_id, ordinal, id);
CREATE INDEX funding_disclosure_entry_category_idx ON editorial.funding_disclosure_entries USING btree (counterparty_category, revision DESC, ordinal, id);
CREATE INDEX funding_disclosure_entry_related_cases_idx ON editorial.funding_disclosure_entries USING gin (related_case_ids) WHERE cardinality(related_case_ids) > 0;
CREATE INDEX funding_disclosure_entry_source_ids_idx ON editorial.funding_disclosure_entries USING gin (source_snapshot_entry_ids);
CREATE INDEX funding_disclosure_entry_revision_fk_idx ON editorial.funding_disclosure_entries USING btree (revision_id, disclosure_id, revision, id);
REVOKE ALL ON editorial.funding_disclosure_entries FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON editorial.funding_disclosure_entries TO gurine_workflow_worker;
GRANT SELECT ON editorial.funding_disclosure_entries TO gurine_control_api;
GRANT SELECT ON editorial.funding_disclosure_entries TO gurine_auditor;
CREATE TABLE ops.sku_readiness_evaluations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  environment text NOT NULL,
  readiness_stage text NOT NULL,
  configuration_digest char(64) NOT NULL,
  catalog_version text NOT NULL,
  catalog_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  offered_optional_capability_ids text[] NOT NULL DEFAULT '{}'::text[],
  offered_capability_set_digest char(64) NOT NULL,
  item_identity_set_digest char(64) NOT NULL,
  evaluation_identity_digest char(64) NOT NULL,
  evaluated_at timestamptz NOT NULL,
  evidence_cutoff_at timestamptz NOT NULL,
  item_count integer NOT NULL,
  required_item_count integer NOT NULL,
  satisfied_required_item_count integer NOT NULL,
  blocked_required_item_count integer NOT NULL,
  unknown_required_item_count integer NOT NULL,
  optional_item_count integer NOT NULL,
  item_set_digest char(64) NOT NULL,
  blocker_set_digest char(64) NOT NULL,
  state text NOT NULL,
  evaluator_build_digest char(64) NOT NULL,
  evaluation_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_sku_readiness_evaluations_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.sku_readiness_evaluations OWNER TO gurine_migrator;
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_identity_uq UNIQUE (deployment_id, organization_id, sku, environment, readiness_stage, evaluation_identity_digest);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_digest_uq UNIQUE (evaluation_digest);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_item_parent_uq UNIQUE (id, deployment_id, organization_id, sku, environment, configuration_digest);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_environment_ck CHECK (environment IN ('development','test','staging','production'));
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_stage_ck CHECK (readiness_stage IN ('PILOT_ENTRY_READINESS','POST_FIRST_BILLING_CYCLE','GENERAL_AVAILABILITY'));
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_catalog_version_ck CHECK (catalog_version = 'evidence-workspace-readiness.v1');
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_offered_no_null_ck CHECK (array_position(offered_optional_capability_ids, NULL) IS NULL);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_offered_values_ck CHECK (offered_optional_capability_ids <@ ARRAY['PUBLIC_WEB','VERIFIED_EMAIL','API_EXPORT','SIGNED_WEBHOOK','DAILY_DIGEST','WEEKLY_DIGEST','delivery.sms','delivery.telegram','delivery.whatsapp','delivery.line','delivery.kakao','delivery.voice']::text[]);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_time_ck CHECK (evidence_cutoff_at <= evaluated_at AND evaluated_at <= recorded_at);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_count_bounds_ck CHECK (item_count > 0 AND required_item_count > 0 AND optional_item_count = 12 AND satisfied_required_item_count >= 0 AND blocked_required_item_count >= 0 AND unknown_required_item_count >= 0);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_required_count_ck CHECK (required_item_count = satisfied_required_item_count + blocked_required_item_count + unknown_required_item_count);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_total_count_ck CHECK (item_count >= optional_item_count AND required_item_count <= item_count);
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_state_ck CHECK ((state = 'READY' AND blocked_required_item_count = 0 AND unknown_required_item_count = 0 AND satisfied_required_item_count = required_item_count) OR (state = 'BLOCKED' AND blocked_required_item_count > 0) OR (state = 'UNKNOWN' AND blocked_required_item_count = 0 AND unknown_required_item_count > 0));
ALTER TABLE ops.sku_readiness_evaluations ADD CONSTRAINT sku_readiness_evaluations_digests_ck CHECK (configuration_digest ~ '^[0-9a-f]{64}$' AND catalog_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND offered_capability_set_digest ~ '^[0-9a-f]{64}$' AND item_identity_set_digest ~ '^[0-9a-f]{64}$' AND evaluation_identity_digest ~ '^[0-9a-f]{64}$' AND item_set_digest ~ '^[0-9a-f]{64}$' AND blocker_set_digest ~ '^[0-9a-f]{64}$' AND evaluator_build_digest ~ '^[0-9a-f]{64}$' AND evaluation_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX sku_readiness_evaluations_latest_idx ON ops.sku_readiness_evaluations USING btree (deployment_id, sku, environment, readiness_stage, evaluated_at DESC, id);
CREATE INDEX sku_readiness_evaluations_state_idx ON ops.sku_readiness_evaluations USING btree (state, evaluated_at DESC, deployment_id, id);
CREATE INDEX sku_readiness_evaluations_org_idx ON ops.sku_readiness_evaluations USING btree (organization_id, evaluated_at DESC, id);
REVOKE ALL ON ops.sku_readiness_evaluations FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.sku_readiness_evaluations TO gurine_workflow_worker;
GRANT SELECT ON ops.sku_readiness_evaluations TO gurine_control_api;
GRANT SELECT ON ops.sku_readiness_evaluations TO gurine_auditor;
CREATE TABLE ops.sku_readiness_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  evaluation_id uuid NOT NULL,
  item_ordinal integer NOT NULL,
  item_code text NOT NULL,
  item_identity_digest char(64) NOT NULL,
  requirement_class text NOT NULL,
  required_for_evaluation boolean NOT NULL,
  item_state text NOT NULL,
  evidence_tier text NOT NULL,
  expected_configuration_digest char(64) NOT NULL,
  activation_decision_id uuid,
  activation_decision_version bigint,
  activation_decision_digest char(64),
  activation_evidence_id uuid,
  activation_evidence_digest char(64),
  commercial_contract_period_id uuid,
  commercial_contract_record_digest char(64),
  tariff_version_id uuid,
  tariff_record_digest char(64),
  invoice_fact_id uuid,
  invoice_reconciliation_digest char(64),
  revenue_fact_id uuid,
  revenue_record_digest char(64),
  cost_allocation_period_id uuid,
  cost_allocation_row_kind text,
  cost_allocation_record_digest char(64),
  cost_allocation_close_receipt_digest char(64),
  outcome_fact_id uuid,
  outcome_fact_digest char(64),
  sli_window_receipt_id uuid,
  sli_id text,
  sli_definition_version text,
  sli_environment text,
  sli_scope_digest char(64),
  sli_window_kind text,
  sli_window_sequence bigint,
  sli_organization_id uuid,
  sli_contract_period_id uuid,
  sli_policy_digest char(64),
  sli_receipt_digest char(64),
  evidence_member_set_digest char(64),
  evidence_as_of timestamptz,
  evidence_expires_at timestamptz,
  measurement_unit text NOT NULL,
  comparator text NOT NULL,
  observed_value numeric(24,6),
  threshold_value numeric(24,6),
  blocker_code text,
  remediation_code text,
  owner_function text NOT NULL,
  item_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_sku_readiness_items_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.sku_readiness_items OWNER TO gurine_migrator;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_ordinal_uq UNIQUE (evaluation_id, item_ordinal);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_code_uq UNIQUE (evaluation_id, item_code);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_identity_uq UNIQUE (evaluation_id, item_identity_digest);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_digest_uq UNIQUE (item_digest);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_ordinal_ck CHECK (item_ordinal > 0);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_code_ck CHECK (item_code IN ('PAID_WORKSPACE_PROCESSING_ACTIVE','DEPLOYMENT_ISOLATION_PROVEN','OIDC_AND_ROSTER_READY','DATA_STORES_KEYS_QUEUES_ISOLATED','SOURCE_RIGHTS_CONFIGURED','TELEMETRY_ALERTS_RUNBOOK_READY','BACKUP_RESTORE_PROVEN','INCIDENT_OWNERSHIP_READY','PUBLIC_WEB_ACTIVE','VERIFIED_EMAIL_ACTIVE','API_EXPORT_ACTIVE','SIGNED_WEBHOOK_ACTIVE','DAILY_DIGEST_ACTIVE','WEEKLY_DIGEST_ACTIVE','CURRENT_CONTRACT_PERIOD','CURRENT_TARIFF_VERSION','BILLING_RECONCILIATION_PATH_READY','COST_CAPTURE_PATH_READY','P75_VARIABLE_GROSS_MARGIN','SUPPORT_CAPACITY','ACTUAL_BILLABLE_RECONCILIATION','ACTUAL_COST_CAPTURE','FIRST_PAID_VERIFIED_WORKFLOW_CYCLE','CAC_PAYBACK','SMS_ADAPTER_ACTIVE','TELEGRAM_ADAPTER_ACTIVE','WHATSAPP_ADAPTER_ACTIVE','LINE_ADAPTER_ACTIVE','KAKAO_ADAPTER_ACTIVE','VOICE_ADAPTER_ACTIVE'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_requirement_class_ck CHECK (requirement_class IN ('MANDATORY','CONDITIONAL_OFFERED','INFORMATIONAL'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_state_value_ck CHECK (item_state IN ('SATISFIED','UNSATISFIED','UNKNOWN','NOT_APPLICABLE'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_evidence_tier_ck CHECK (evidence_tier IN ('PRODUCTION_LIVE','PRODUCTION_DERIVED','PRODUCTION_PREFLIGHT','NON_PRODUCTION_PREFLIGHT','FIXTURE_ONLY','MISSING'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_activation_decision_tuple_ck CHECK ((activation_decision_id IS NULL AND activation_decision_version IS NULL AND activation_decision_digest IS NULL) OR (activation_decision_id IS NOT NULL AND activation_decision_version IS NOT NULL AND activation_decision_version > 0 AND activation_decision_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_activation_evidence_tuple_ck CHECK ((activation_evidence_id IS NULL AND activation_evidence_digest IS NULL) OR (activation_evidence_id IS NOT NULL AND activation_evidence_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_activation_evidence_parent_ck CHECK (activation_evidence_id IS NULL OR activation_decision_id IS NOT NULL);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_contract_tuple_ck CHECK ((commercial_contract_period_id IS NULL AND commercial_contract_record_digest IS NULL) OR (commercial_contract_period_id IS NOT NULL AND commercial_contract_record_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_tariff_tuple_ck CHECK ((tariff_version_id IS NULL AND tariff_record_digest IS NULL) OR (tariff_version_id IS NOT NULL AND tariff_record_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_invoice_tuple_ck CHECK ((invoice_fact_id IS NULL AND invoice_reconciliation_digest IS NULL) OR (invoice_fact_id IS NOT NULL AND invoice_reconciliation_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_revenue_tuple_ck CHECK ((revenue_fact_id IS NULL AND revenue_record_digest IS NULL) OR (revenue_fact_id IS NOT NULL AND revenue_record_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_cost_allocation_tuple_ck CHECK ((cost_allocation_period_id IS NULL AND cost_allocation_row_kind IS NULL AND cost_allocation_record_digest IS NULL AND cost_allocation_close_receipt_digest IS NULL) OR (cost_allocation_period_id IS NOT NULL AND cost_allocation_row_kind = 'PERIOD' AND cost_allocation_record_digest IS NOT NULL AND cost_allocation_close_receipt_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_outcome_tuple_ck CHECK ((outcome_fact_id IS NULL AND outcome_fact_digest IS NULL) OR (outcome_fact_id IS NOT NULL AND outcome_fact_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_sli_tuple_ck CHECK ((sli_window_receipt_id IS NULL AND sli_id IS NULL AND sli_definition_version IS NULL AND sli_environment IS NULL AND sli_scope_digest IS NULL AND sli_window_kind IS NULL AND sli_window_sequence IS NULL AND sli_organization_id IS NULL AND sli_contract_period_id IS NULL AND sli_policy_digest IS NULL AND sli_receipt_digest IS NULL) OR (sli_window_receipt_id IS NOT NULL AND sli_id IS NOT NULL AND sli_id ~ '^[a-z][a-z0-9_.-]{2,159}$' AND sli_definition_version IS NOT NULL AND length(sli_definition_version) BETWEEN 1 AND 100 AND sli_environment = 'PRODUCTION' AND sli_scope_digest IS NOT NULL AND sli_window_kind IS NOT NULL AND sli_window_sequence IS NOT NULL AND sli_window_sequence > 0 AND sli_organization_id IS NOT NULL AND sli_contract_period_id IS NOT NULL AND sli_policy_digest IS NOT NULL AND sli_receipt_digest IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_measurement_unit_ck CHECK (measurement_unit IN ('BOOLEAN','RATIO','HOURS_PER_MONTH','MONTHS','COUNT'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_comparator_ck CHECK (comparator IN ('EQ','GTE','LTE'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_boolean_measurement_ck CHECK (measurement_unit <> 'BOOLEAN' OR (comparator = 'EQ' AND threshold_value = 1));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_ratio_measurement_ck CHECK (measurement_unit <> 'RATIO' OR observed_value IS NULL OR observed_value BETWEEN 0 AND 1);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_measurement_presence_ck CHECK ((threshold_value IS NULL AND observed_value IS NULL) OR (threshold_value IS NOT NULL AND observed_value IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_satisfied_ck CHECK (item_state <> 'SATISFIED' OR (observed_value IS NOT NULL AND evidence_as_of IS NOT NULL AND evidence_tier IN ('PRODUCTION_LIVE','PRODUCTION_DERIVED','PRODUCTION_PREFLIGHT') AND blocker_code IS NULL AND remediation_code IS NULL AND num_nonnulls(activation_decision_id,activation_evidence_id,commercial_contract_period_id,tariff_version_id,invoice_fact_id,revenue_fact_id,cost_allocation_period_id,outcome_fact_id,sli_window_receipt_id,evidence_member_set_digest) > 0));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_blocked_ck CHECK (item_state NOT IN ('UNSATISFIED','UNKNOWN') OR (blocker_code IS NOT NULL AND remediation_code IS NOT NULL));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_not_applicable_ck CHECK (item_state <> 'NOT_APPLICABLE' OR (required_for_evaluation = false AND requirement_class <> 'MANDATORY'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_required_ck CHECK (required_for_evaluation = false OR item_state <> 'NOT_APPLICABLE');
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_evidence_interval_ck CHECK (evidence_expires_at IS NULL OR evidence_as_of IS NULL OR evidence_expires_at > evidence_as_of);
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_blocker_code_ck CHECK (blocker_code IS NULL OR blocker_code IN ('EVIDENCE_MISSING','EVIDENCE_STALE','EVIDENCE_NOT_PRODUCTION_GRADE','CONFIGURATION_MISMATCH','CAPABILITY_NOT_ACTIVE','CONTRACT_NOT_CURRENT','TARIFF_NOT_CURRENT','RECONCILIATION_COVERAGE_BELOW_TARGET','COST_CAPTURE_BELOW_TARGET','MARGIN_BELOW_TARGET','SUPPORT_CAPACITY_ABOVE_TARGET','CAC_PAYBACK_ABOVE_TARGET','VERIFIED_WORKFLOW_CYCLE_MISSING','LEGAL_OR_RIGHTS_BLOCKED','KILL_SWITCH_ACTIVE','INCIDENT_OR_SLO_BLOCKED'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_remediation_code_ck CHECK (remediation_code IS NULL OR remediation_code IN ('RECORD_CURRENT_EVIDENCE','REEVALUATE_EXACT_CONFIGURATION','COMPLETE_CAPABILITY_ACTIVATION','ACTIVATE_COMMERCIAL_CONTRACT','ACTIVATE_TARIFF_VERSION','RECONCILE_BILLABLE_FACTS','CLOSE_COST_ALLOCATION_PERIOD','ADJUST_PRICE_QUOTA_OR_EFFICIENCY','RESTORE_SUPPORT_CAPACITY','RECORD_FIRST_VERIFIED_WORKFLOW','RESOLVE_LEGAL_RIGHTS_OR_SWITCH_BLOCKER','RESOLVE_INCIDENT_AND_REEVALUATE'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_owner_function_ck CHECK (owner_function IN ('PRODUCT_PDM','EDITORIAL_DUTY','DATA_ENGINEERING','SRE_ON_CALL','LEGAL_PRIVACY','SALES_CS_FINANCE','INDEPENDENT_REVIEW_PUBLISHER'));
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_digests_ck CHECK (expected_configuration_digest ~ '^[0-9a-f]{64}$' AND item_identity_digest ~ '^[0-9a-f]{64}$' AND (activation_decision_digest IS NULL OR activation_decision_digest ~ '^[0-9a-f]{64}$') AND (activation_evidence_digest IS NULL OR activation_evidence_digest ~ '^[0-9a-f]{64}$') AND (commercial_contract_record_digest IS NULL OR commercial_contract_record_digest ~ '^[0-9a-f]{64}$') AND (tariff_record_digest IS NULL OR tariff_record_digest ~ '^[0-9a-f]{64}$') AND (invoice_reconciliation_digest IS NULL OR invoice_reconciliation_digest ~ '^[0-9a-f]{64}$') AND (revenue_record_digest IS NULL OR revenue_record_digest ~ '^[0-9a-f]{64}$') AND (cost_allocation_record_digest IS NULL OR cost_allocation_record_digest ~ '^[0-9a-f]{64}$') AND (cost_allocation_close_receipt_digest IS NULL OR cost_allocation_close_receipt_digest ~ '^[0-9a-f]{64}$') AND (outcome_fact_digest IS NULL OR outcome_fact_digest ~ '^[0-9a-f]{64}$') AND (sli_scope_digest IS NULL OR sli_scope_digest ~ '^[0-9a-f]{64}$') AND (sli_policy_digest IS NULL OR sli_policy_digest ~ '^[0-9a-f]{64}$') AND (sli_receipt_digest IS NULL OR sli_receipt_digest ~ '^[0-9a-f]{64}$') AND (evidence_member_set_digest IS NULL OR evidence_member_set_digest ~ '^[0-9a-f]{64}$') AND item_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX sku_readiness_items_evaluation_order_idx ON ops.sku_readiness_items USING btree (evaluation_id, item_ordinal, id);
CREATE INDEX sku_readiness_items_blocker_idx ON ops.sku_readiness_items USING btree (evaluation_id, required_for_evaluation, item_state, item_ordinal) WHERE required_for_evaluation AND item_state IN ('UNSATISFIED','UNKNOWN');
CREATE INDEX sku_readiness_items_activation_idx ON ops.sku_readiness_items USING btree (activation_decision_id, activation_decision_version) WHERE activation_decision_id IS NOT NULL;
CREATE INDEX sku_readiness_items_expiry_idx ON ops.sku_readiness_items USING btree (evidence_expires_at, item_state) WHERE evidence_expires_at IS NOT NULL;
CREATE INDEX sku_readiness_items_activation_decision_fk_idx ON ops.sku_readiness_items USING btree (activation_decision_id, activation_decision_version, activation_decision_digest, id) WHERE activation_decision_id IS NOT NULL;
CREATE INDEX sku_readiness_items_activation_evidence_fk_idx ON ops.sku_readiness_items USING btree (activation_evidence_id, activation_decision_id, activation_evidence_digest, id) WHERE activation_evidence_id IS NOT NULL;
CREATE INDEX sku_readiness_items_contract_period_fk_idx ON ops.sku_readiness_items USING btree (commercial_contract_period_id, id) WHERE commercial_contract_period_id IS NOT NULL;
CREATE INDEX sku_readiness_items_tariff_fk_idx ON ops.sku_readiness_items USING btree (tariff_version_id, id) WHERE tariff_version_id IS NOT NULL;
CREATE INDEX sku_readiness_items_invoice_fk_idx ON ops.sku_readiness_items USING btree (invoice_fact_id, id) WHERE invoice_fact_id IS NOT NULL;
CREATE INDEX sku_readiness_items_revenue_fk_idx ON ops.sku_readiness_items USING btree (revenue_fact_id, id) WHERE revenue_fact_id IS NOT NULL;
CREATE INDEX sku_readiness_items_cost_allocation_fk_idx ON ops.sku_readiness_items USING btree (cost_allocation_period_id, cost_allocation_row_kind, id) WHERE cost_allocation_period_id IS NOT NULL;
CREATE INDEX sku_readiness_items_outcome_fact_fk_idx ON ops.sku_readiness_items USING btree (outcome_fact_id, id) WHERE outcome_fact_id IS NOT NULL;
CREATE INDEX sku_readiness_items_sli_fk_idx ON ops.sku_readiness_items USING btree (sli_window_receipt_id, sli_id, sli_definition_version, sli_environment, sli_scope_digest, sli_window_kind, sli_window_sequence, sli_receipt_digest, id) WHERE sli_window_receipt_id IS NOT NULL;
CREATE INDEX sku_readiness_items_sli_contract_fk_idx ON ops.sku_readiness_items USING btree (sli_contract_period_id, sli_organization_id, sli_policy_digest, id) WHERE sli_contract_period_id IS NOT NULL;
REVOKE ALL ON ops.sku_readiness_items FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.sku_readiness_items TO gurine_workflow_worker;
GRANT SELECT ON ops.sku_readiness_items TO gurine_control_api;
GRANT SELECT ON ops.sku_readiness_items TO gurine_auditor;
CREATE TABLE ops.accounting_corrections (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  deployment_id uuid NOT NULL,
  scope_kind ops.accounting_scope_kind NOT NULL,
  organization_id uuid,
  accounting_timezone text NOT NULL,
  accounting_policy_digest char(64) NOT NULL,
  root_correction_id uuid NOT NULL,
  revision bigint NOT NULL,
  correction_sequence bigint NOT NULL,
  correction_kind ops.accounting_correction_kind NOT NULL,
  supersedes_correction_id uuid,
  reverses_correction_id uuid,
  predecessor_correction_digest char(64),
  source_system_id text NOT NULL,
  source_record_identity_digest char(64) NOT NULL,
  correction_identity_digest char(64) NOT NULL,
  target_fact_kind ops.accounting_fact_kind NOT NULL,
  target_amount_kind ops.accounting_target_amount_kind NOT NULL,
  target_fact_id uuid NOT NULL,
  target_cost_event_id uuid,
  target_cost_allocation_id uuid,
  target_invoice_fact_id uuid,
  target_invoice_line_fact_id uuid,
  target_revenue_fact_id uuid,
  target_fact_digest char(64) NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  amount numeric(24,6) NOT NULL,
  effective_delta numeric(24,6) NOT NULL,
  resulting_effective_amount numeric(24,6) NOT NULL,
  resulting_correction_set_digest char(64) NOT NULL,
  currency char(3) NOT NULL,
  reason_code ops.accounting_correction_reason NOT NULL,
  proposed_by uuid NOT NULL,
  approver_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  source_receipt_digest char(64) NOT NULL,
  signature_digest char(64) NOT NULL,
  record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_accounting_corrections_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.accounting_corrections OWNER TO gurine_migrator;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_root_revision_uq UNIQUE (root_correction_id, revision);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_target_sequence_uq UNIQUE (target_fact_kind, target_fact_id, target_amount_kind, correction_sequence);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_source_identity_uq UNIQUE (deployment_id, source_system_id, source_record_identity_digest, target_fact_kind, target_fact_id, target_amount_kind);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_identity_digest_uq UNIQUE (correction_identity_digest);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_record_digest_uq UNIQUE (record_digest);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_scope_ck CHECK ((scope_kind = 'DEPLOYMENT' AND organization_id IS NULL) OR (scope_kind = 'ORGANIZATION' AND organization_id IS NOT NULL));
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_revision_ck CHECK (revision > 0 AND correction_sequence > 0);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_interval_ck CHECK (period_start < period_end);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_timezone_ck CHECK (length(btrim(accounting_timezone)) BETWEEN 1 AND 63);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_amount_ck CHECK (((correction_kind IN ('ADJUSTMENT','REPLACEMENT') AND amount <> 0) OR (correction_kind = 'REVERSAL' AND amount = 0)) AND effective_delta <> 0 AND resulting_effective_amount >= 0 AND currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_sod_ck CHECK (proposed_by <> approver_id);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_chain_shape_ck CHECK ((correction_kind = 'ADJUSTMENT' AND revision = 1 AND root_correction_id = id AND supersedes_correction_id IS NULL AND reverses_correction_id IS NULL AND predecessor_correction_digest IS NULL AND effective_delta = amount) OR (correction_kind = 'REPLACEMENT' AND revision > 1 AND root_correction_id <> id AND supersedes_correction_id IS NOT NULL AND reverses_correction_id IS NULL AND predecessor_correction_digest IS NOT NULL) OR (correction_kind = 'REVERSAL' AND revision > 1 AND root_correction_id <> id AND supersedes_correction_id IS NULL AND reverses_correction_id IS NOT NULL AND predecessor_correction_digest IS NOT NULL));
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_target_ck CHECK ((num_nonnulls(target_cost_event_id, target_cost_allocation_id, target_invoice_fact_id, target_invoice_line_fact_id, target_revenue_fact_id) = 1 AND target_fact_id IS NOT DISTINCT FROM CASE target_fact_kind WHEN 'COST_EVENT' THEN target_cost_event_id WHEN 'COST_ALLOCATION' THEN target_cost_allocation_id WHEN 'INVOICE_FACT' THEN target_invoice_fact_id WHEN 'INVOICE_LINE_FACT' THEN target_invoice_line_fact_id WHEN 'REVENUE_FACT' THEN target_revenue_fact_id ELSE NULL END AND CASE target_fact_kind WHEN 'COST_EVENT' THEN target_cost_event_id WHEN 'COST_ALLOCATION' THEN target_cost_allocation_id WHEN 'INVOICE_FACT' THEN target_invoice_fact_id WHEN 'INVOICE_LINE_FACT' THEN target_invoice_line_fact_id WHEN 'REVENUE_FACT' THEN target_revenue_fact_id ELSE NULL END IS NOT NULL) IS TRUE);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_target_amount_kind_ck CHECK (((target_fact_kind = 'COST_EVENT' AND target_amount_kind = 'COST_EVENT_AMOUNT') OR (target_fact_kind = 'COST_ALLOCATION' AND target_amount_kind IN ('COST_ALLOCATION_ALLOCATED_AMOUNT','COST_ALLOCATION_UNALLOCATED_AMOUNT')) OR (target_fact_kind = 'INVOICE_FACT' AND target_amount_kind = 'INVOICE_TOTAL') OR (target_fact_kind = 'INVOICE_LINE_FACT' AND target_amount_kind = 'INVOICE_LINE_TOTAL') OR (target_fact_kind = 'REVENUE_FACT' AND target_amount_kind = 'REVENUE_AMOUNT')) IS TRUE);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_source_system_ck CHECK (length(btrim(source_system_id)) BETWEEN 1 AND 100);
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_digest_ck CHECK (source_record_identity_digest ~ '^[0-9a-f]{64}$' AND correction_identity_digest ~ '^[0-9a-f]{64}$' AND accounting_policy_digest ~ '^[0-9a-f]{64}$' AND target_fact_digest ~ '^[0-9a-f]{64}$' AND (predecessor_correction_digest IS NULL OR predecessor_correction_digest ~ '^[0-9a-f]{64}$') AND resulting_correction_set_digest ~ '^[0-9a-f]{64}$' AND decision_digest ~ '^[0-9a-f]{64}$' AND source_receipt_digest ~ '^[0-9a-f]{64}$' AND signature_digest ~ '^[0-9a-f]{64}$' AND record_digest ~ '^[0-9a-f]{64}$');
CREATE INDEX accounting_correction_target_idx ON ops.accounting_corrections USING btree (target_fact_kind, target_fact_id, target_amount_kind, correction_sequence ASC, id);
CREATE INDEX accounting_correction_root_history_idx ON ops.accounting_corrections USING btree (root_correction_id, revision ASC, id);
CREATE INDEX accounting_correction_period_idx ON ops.accounting_corrections USING btree (deployment_id, period_start ASC, period_end ASC, id);
CREATE INDEX accounting_correction_supersedes_fk_idx ON ops.accounting_corrections USING btree (supersedes_correction_id, id) WHERE supersedes_correction_id IS NOT NULL;
CREATE INDEX accounting_correction_reverses_fk_idx ON ops.accounting_corrections USING btree (reverses_correction_id, id) WHERE reverses_correction_id IS NOT NULL;
CREATE INDEX accounting_correction_cost_event_fk_idx ON ops.accounting_corrections USING btree (target_cost_event_id, id) WHERE target_cost_event_id IS NOT NULL;
CREATE INDEX accounting_correction_cost_allocation_fk_idx ON ops.accounting_corrections USING btree (target_cost_allocation_id, id) WHERE target_cost_allocation_id IS NOT NULL;
CREATE INDEX accounting_correction_invoice_fact_fk_idx ON ops.accounting_corrections USING btree (target_invoice_fact_id, id) WHERE target_invoice_fact_id IS NOT NULL;
CREATE INDEX accounting_correction_invoice_line_fk_idx ON ops.accounting_corrections USING btree (target_invoice_line_fact_id, id) WHERE target_invoice_line_fact_id IS NOT NULL;
CREATE INDEX accounting_correction_revenue_fact_fk_idx ON ops.accounting_corrections USING btree (target_revenue_fact_id, id) WHERE target_revenue_fact_id IS NOT NULL;
CREATE INDEX accounting_correction_proposer_fk_idx ON ops.accounting_corrections USING btree (proposed_by, id);
CREATE INDEX accounting_correction_approver_fk_idx ON ops.accounting_corrections USING btree (approver_id, id);
REVOKE ALL ON ops.accounting_corrections FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.accounting_corrections TO gurine_workflow_worker;
GRANT SELECT ON ops.accounting_corrections TO gurine_control_api;
GRANT SELECT ON ops.accounting_corrections TO gurine_auditor;
CREATE TABLE ops.commercial_qualification_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  root_receipt_id uuid NOT NULL,
  revision bigint NOT NULL,
  receipt_effect ops.commercial_qualification_receipt_effect NOT NULL,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  qualification_episode_id uuid NOT NULL,
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  decision_effective_at timestamptz NOT NULL,
  first_qualified_at timestamptz NOT NULL,
  recurring_job_attested boolean NOT NULL,
  authorized_data_identified boolean NOT NULL,
  authorized_data_feasible boolean NOT NULL,
  economic_buyer_role_bound boolean NOT NULL,
  operational_owner_role_bound boolean NOT NULL,
  independent_reviewer_role_bound boolean NOT NULL,
  source_rights_owner_role_bound boolean NOT NULL,
  incident_support_owner_role_bound boolean NOT NULL,
  pilot_scope_accepted boolean NOT NULL,
  success_metric_accepted boolean NOT NULL,
  budget_authority_accepted boolean NOT NULL,
  support_expectation_accepted boolean NOT NULL,
  trust_terms_accepted boolean NOT NULL,
  role_binding_hmac_key_version text NOT NULL,
  economic_buyer_primary_role_binding_hmac char(64) NOT NULL,
  economic_buyer_backup_role_binding_hmac char(64) NOT NULL,
  operational_owner_primary_role_binding_hmac char(64) NOT NULL,
  operational_owner_backup_role_binding_hmac char(64) NOT NULL,
  independent_reviewer_primary_role_binding_hmac char(64) NOT NULL,
  independent_reviewer_backup_role_binding_hmac char(64) NOT NULL,
  source_rights_owner_primary_role_binding_hmac char(64) NOT NULL,
  source_rights_owner_backup_role_binding_hmac char(64) NOT NULL,
  incident_support_owner_primary_role_binding_hmac char(64) NOT NULL,
  incident_support_owner_backup_role_binding_hmac char(64) NOT NULL,
  source_system_id text NOT NULL,
  source_record_identity_hmac char(64) NOT NULL,
  acquisition_source_receipt_id uuid,
  acquisition_source_receipt_digest char(64),
  source_signature_digest char(64) NOT NULL,
  qualification_policy_version bigint NOT NULL,
  qualification_policy_digest char(64) NOT NULL,
  criterion_set_digest char(64) NOT NULL,
  role_binding_set_digest char(64) NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  reason_code ops.commercial_qualification_reason NOT NULL,
  receipt_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_commercial_qualification_receipts_pkey PRIMARY KEY (id)
);
ALTER TABLE ops.commercial_qualification_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_root_revision_uq UNIQUE (root_receipt_id, revision);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_episode_revision_uq UNIQUE (deployment_id, organization_id, sku, qualification_episode_id, revision);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_receipt_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_reference_uq UNIQUE (id, receipt_digest);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_offer_binding_uq UNIQUE (id, deployment_id, organization_id, sku, qualification_episode_id, receipt_digest);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_paid_packet_binding_uq UNIQUE (id, deployment_id, organization_id, sku, qualification_episode_id, revision, receipt_digest);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_invalidation_binding_uq UNIQUE (id, revision, receipt_digest);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_revision_ck CHECK (revision > 0 AND qualification_policy_version > 0);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_time_ck CHECK (first_qualified_at <= decision_effective_at AND decision_effective_at <= recorded_at);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_chain_ck CHECK ((receipt_effect = 'ORIGINAL' AND revision = 1 AND root_receipt_id = id AND supersedes_receipt_id IS NULL AND predecessor_receipt_digest IS NULL AND first_qualified_at = decision_effective_at AND reason_code = 'QUALIFICATION_ACCEPTED') OR (receipt_effect = 'REPLACEMENT' AND revision > 1 AND root_receipt_id <> id AND supersedes_receipt_id IS NOT NULL AND predecessor_receipt_digest IS NOT NULL AND reason_code = 'SOURCE_CORRECTION') OR (receipt_effect = 'REVERSAL' AND revision > 1 AND root_receipt_id <> id AND supersedes_receipt_id IS NOT NULL AND predecessor_receipt_digest IS NOT NULL AND reason_code = 'SOURCE_REVERSAL'));
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_criteria_ck CHECK ((receipt_effect IN ('ORIGINAL','REPLACEMENT') AND recurring_job_attested AND authorized_data_identified AND authorized_data_feasible AND economic_buyer_role_bound AND operational_owner_role_bound AND independent_reviewer_role_bound AND source_rights_owner_role_bound AND incident_support_owner_role_bound AND pilot_scope_accepted AND success_metric_accepted AND budget_authority_accepted AND support_expectation_accepted AND trust_terms_accepted) OR (receipt_effect = 'REVERSAL' AND NOT recurring_job_attested AND NOT authorized_data_identified AND NOT authorized_data_feasible AND NOT economic_buyer_role_bound AND NOT operational_owner_role_bound AND NOT independent_reviewer_role_bound AND NOT source_rights_owner_role_bound AND NOT incident_support_owner_role_bound AND NOT pilot_scope_accepted AND NOT success_metric_accepted AND NOT budget_authority_accepted AND NOT support_expectation_accepted AND NOT trust_terms_accepted));
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1');
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_source_ck CHECK (source_system_id ~ '^[a-z0-9][a-z0-9._-]{0,127}$' AND length(btrim(role_binding_hmac_key_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_role_distinct_ck CHECK (economic_buyer_primary_role_binding_hmac <> economic_buyer_backup_role_binding_hmac AND operational_owner_primary_role_binding_hmac <> operational_owner_backup_role_binding_hmac AND independent_reviewer_primary_role_binding_hmac <> independent_reviewer_backup_role_binding_hmac AND source_rights_owner_primary_role_binding_hmac <> source_rights_owner_backup_role_binding_hmac AND incident_support_owner_primary_role_binding_hmac <> incident_support_owner_backup_role_binding_hmac);
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_acquisition_pair_ck CHECK ((acquisition_source_receipt_id IS NULL) = (acquisition_source_receipt_digest IS NULL));
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_digest_ck CHECK ((predecessor_receipt_digest IS NULL OR predecessor_receipt_digest ~ '^[0-9a-f]{64}$') AND economic_buyer_primary_role_binding_hmac ~ '^[0-9a-f]{64}$' AND economic_buyer_backup_role_binding_hmac ~ '^[0-9a-f]{64}$' AND operational_owner_primary_role_binding_hmac ~ '^[0-9a-f]{64}$' AND operational_owner_backup_role_binding_hmac ~ '^[0-9a-f]{64}$' AND independent_reviewer_primary_role_binding_hmac ~ '^[0-9a-f]{64}$' AND independent_reviewer_backup_role_binding_hmac ~ '^[0-9a-f]{64}$' AND source_rights_owner_primary_role_binding_hmac ~ '^[0-9a-f]{64}$' AND source_rights_owner_backup_role_binding_hmac ~ '^[0-9a-f]{64}$' AND incident_support_owner_primary_role_binding_hmac ~ '^[0-9a-f]{64}$' AND incident_support_owner_backup_role_binding_hmac ~ '^[0-9a-f]{64}$' AND source_record_identity_hmac ~ '^[0-9a-f]{64}$' AND (acquisition_source_receipt_digest IS NULL OR acquisition_source_receipt_digest ~ '^[0-9a-f]{64}$') AND source_signature_digest ~ '^[0-9a-f]{64}$' AND qualification_policy_digest ~ '^[0-9a-f]{64}$' AND criterion_set_digest ~ '^[0-9a-f]{64}$' AND role_binding_set_digest ~ '^[0-9a-f]{64}$' AND evidence_set_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX commercial_qualification_one_successor_uq ON ops.commercial_qualification_receipts USING btree (supersedes_receipt_id) WHERE supersedes_receipt_id IS NOT NULL;
CREATE UNIQUE INDEX commercial_qualification_acquisition_once_uq ON ops.commercial_qualification_receipts USING btree (acquisition_source_receipt_id, acquisition_source_receipt_digest) WHERE receipt_effect = 'ORIGINAL' AND acquisition_source_receipt_id IS NOT NULL;
CREATE INDEX commercial_qualification_episode_history_idx ON ops.commercial_qualification_receipts USING btree (deployment_id, organization_id, sku, qualification_episode_id, decision_effective_at ASC, revision ASC, id ASC);
CREATE INDEX commercial_qualification_current_lookup_idx ON ops.commercial_qualification_receipts USING btree (deployment_id, organization_id, sku, decision_effective_at DESC, revision DESC, id DESC);
REVOKE ALL ON ops.commercial_qualification_receipts FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.commercial_qualification_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.commercial_qualification_receipts TO gurine_control_api;
GRANT SELECT ON ops.commercial_qualification_receipts TO gurine_auditor;
CREATE TABLE ops.offer_profile_capabilities (
  contract_period_id uuid NOT NULL,
  offer_profile_id uuid NOT NULL,
  offer_profile_version bigint NOT NULL,
  offer_profile_digest char(64) NOT NULL,
  offer_capability_set_digest char(64) NOT NULL,
  offer_quota_set_digest char(64) NOT NULL,
  offer_overage_policy_set_digest char(64) NOT NULL,
  offer_service_credit_policy_digest char(64) NOT NULL,
  capability_ordinal smallint NOT NULL,
  capability_code ops.offer_capability_code NOT NULL,
  offer_state ops.offer_capability_state NOT NULL,
  quota_kind ops.offer_quota_kind NOT NULL,
  included_quantity numeric(24,6),
  overage_policy ops.offer_overage_policy NOT NULL,
  overage_unit_price numeric(24,6),
  activation_policy_digest char(64),
  consent_policy_digest char(64),
  cost_policy_digest char(64),
  entry_payload jsonb NOT NULL,
  entry_canonical bytea NOT NULL,
  entry_digest_preimage_canonical bytea NOT NULL,
  entry_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_offer_profile_capabilities_pkey PRIMARY KEY (contract_period_id, capability_ordinal)
);
ALTER TABLE ops.offer_profile_capabilities OWNER TO gurine_migrator;
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_profile_ordinal_uq UNIQUE (offer_profile_id, offer_profile_version, capability_ordinal);
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_profile_code_uq UNIQUE (offer_profile_id, offer_profile_version, capability_code);
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_entry_digest_uq UNIQUE (offer_profile_id, offer_profile_version, entry_digest);
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_version_ordinal_ck CHECK (offer_profile_version > 0 AND capability_ordinal BETWEEN 1 AND 12);
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_ordinal_code_ck CHECK ((capability_ordinal,capability_code) IN ((1,'PUBLIC_WEB'),(2,'VERIFIED_EMAIL'),(3,'API_EXPORT'),(4,'SIGNED_WEBHOOK'),(5,'DAILY_DIGEST'),(6,'WEEKLY_DIGEST'),(7,'SMS'),(8,'TELEGRAM'),(9,'WHATSAPP'),(10,'LINE'),(11,'KAKAO'),(12,'VOICE')));
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_offer_shape_ck CHECK ((offer_state = 'NOT_OFFERED' AND quota_kind = 'NOT_METERED' AND included_quantity IS NULL AND overage_policy = 'NOT_APPLICABLE' AND overage_unit_price IS NULL AND activation_policy_digest IS NULL AND consent_policy_digest IS NULL AND cost_policy_digest IS NULL) OR (offer_state = 'INCLUDED_REQUIRED' AND capability_code = 'PUBLIC_WEB' AND quota_kind = 'NOT_METERED' AND included_quantity IS NULL AND overage_policy = 'NOT_APPLICABLE' AND overage_unit_price IS NULL) OR (offer_state = 'INCLUDED_REQUIRED' AND capability_code = 'API_EXPORT' AND quota_kind = 'API_RECORD_UNIT' AND included_quantity IS NOT NULL AND included_quantity >= 0 AND ((overage_policy = 'DECLARED_TARIFF_OVERAGE' AND overage_unit_price IS NOT NULL AND overage_unit_price >= 0) OR (overage_policy = 'HARD_LIMIT_NO_OVERAGE' AND overage_unit_price IS NULL))) OR (offer_state = 'INCLUDED_REQUIRED' AND capability_code = 'SIGNED_WEBHOOK' AND quota_kind = 'WEBHOOK_DISPATCH' AND included_quantity IS NOT NULL AND included_quantity >= 0 AND overage_policy = 'HARD_LIMIT_NO_OVERAGE' AND overage_unit_price IS NULL) OR (offer_state = 'INCLUDED_REQUIRED' AND capability_code IN ('DAILY_DIGEST','WEEKLY_DIGEST') AND quota_kind = 'DIGEST_DISPATCH' AND included_quantity IS NOT NULL AND included_quantity >= 0 AND overage_policy = 'HARD_LIMIT_NO_OVERAGE' AND overage_unit_price IS NULL) OR (offer_state = 'INCLUDED_REQUIRED' AND capability_code IN ('VERIFIED_EMAIL','SMS','TELEGRAM','WHATSAPP','LINE','KAKAO','VOICE') AND quota_kind = 'DELIVERY_ATTEMPT' AND included_quantity IS NOT NULL AND included_quantity >= 0 AND overage_policy = 'HARD_LIMIT_NO_OVERAGE' AND overage_unit_price IS NULL));
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_digest_ck CHECK (offer_profile_digest ~ '^[0-9a-f]{64}$' AND offer_capability_set_digest ~ '^[0-9a-f]{64}$' AND offer_quota_set_digest ~ '^[0-9a-f]{64}$' AND offer_overage_policy_set_digest ~ '^[0-9a-f]{64}$' AND offer_service_credit_policy_digest ~ '^[0-9a-f]{64}$' AND (activation_policy_digest IS NULL OR activation_policy_digest ~ '^[0-9a-f]{64}$') AND (consent_policy_digest IS NULL OR consent_policy_digest ~ '^[0-9a-f]{64}$') AND (cost_policy_digest IS NULL OR cost_policy_digest ~ '^[0-9a-f]{64}$') AND entry_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_canonical_ck CHECK (ops.offer_capability_v1_is_valid(entry_payload) AND convert_from(entry_canonical,'UTF8')::jsonb = entry_payload AND entry_digest = encode(extensions.digest(entry_digest_preimage_canonical,'sha256'),'hex') AND entry_payload->>'entryDigest' = entry_digest);
CREATE INDEX offer_profile_capability_parent_fk_idx ON ops.offer_profile_capabilities USING btree (contract_period_id, offer_profile_id, offer_profile_version, offer_profile_digest);
CREATE INDEX offer_profile_capability_offer_lookup_idx ON ops.offer_profile_capabilities USING btree (offer_profile_id, offer_profile_version, capability_ordinal);
REVOKE ALL ON ops.offer_profile_capabilities FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.offer_profile_capabilities TO gurine_workflow_worker;
GRANT SELECT ON ops.offer_profile_capabilities TO gurine_control_api;
GRANT SELECT ON ops.offer_profile_capabilities TO gurine_auditor;
CREATE TABLE ops.paid_evidence_packets (
  packet_id uuid NOT NULL,
  packet_version bigint NOT NULL,
  state ops.paid_evidence_packet_state NOT NULL,
  predecessor_packet_version bigint,
  predecessor_packet_record_digest char(64),
  deployment_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  sku ops.commercial_sku NOT NULL,
  qualification_receipt_id uuid NOT NULL,
  qualification_episode_id uuid NOT NULL,
  qualification_episode_version bigint NOT NULL,
  qualification_episode_digest char(64) NOT NULL,
  commercial_contract_id uuid NOT NULL,
  commercial_contract_version bigint NOT NULL,
  commercial_contract_digest char(64) NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_case_id uuid NOT NULL,
  review_snapshot_version bigint NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  review_member_set_digest char(64) NOT NULL,
  paid_member_manifest_digest char(64) NOT NULL,
  subject_kind ops.paid_evidence_subject_kind NOT NULL,
  subject_delivery_id uuid,
  subject_rendering_digest char(64),
  subject_authorization_snapshot_digest char(64),
  decision_cycle_id uuid,
  decision_cycle_version bigint,
  decision_cycle_digest char(64),
  subject_binding_payload jsonb NOT NULL,
  subject_binding_canonical bytea NOT NULL,
  packet_subject_digest char(64) NOT NULL,
  member_count smallint NOT NULL,
  member_set_digest char(64) NOT NULL,
  source_event_id uuid NOT NULL,
  source_event_envelope_digest char(64) NOT NULL,
  binding_source_event_id uuid,
  binding_source_event_envelope_digest char(64),
  binding_logical_consumer text,
  terminal_receipt_kind ops.paid_terminal_receipt_kind,
  terminal_receipt_id uuid,
  terminal_receipt_version bigint,
  terminal_receipt_digest char(64),
  terminal_resulting_state ops.paid_terminal_resulting_state,
  terminal_applied boolean,
  terminal_binding_digest char(64),
  terminal_effective_at timestamptz,
  delivery_receipt_id uuid,
  delivery_id uuid,
  delivery_receipt_sequence bigint,
  delivery_receipt_digest char(64),
  delivery_resulting_state text,
  delivery_applied boolean,
  delivery_projection_disposition text,
  delivery_resulting_proof_level text,
  delivery_observed_at timestamptz,
  decision_receipt_id uuid,
  decision_proposal_id uuid,
  decision_proposal_version bigint,
  decision_approval_digest char(64),
  decision_receipt_digest char(64),
  decision_actor_id uuid,
  decision_kind text,
  decision_conflict_snapshot_digest char(64),
  decision_record_kind text,
  decision_resulting_proposal_state text,
  decision_decided_at timestamptz,
  execution_receipt_id uuid,
  execution_id uuid,
  execution_generation bigint,
  execution_receipt_sequence bigint,
  execution_receipt_digest char(64),
  execution_receipt_kind text,
  execution_aggregate_state text,
  execution_mutates_aggregate_state boolean,
  execution_observed_at timestamptz,
  execution_proposal_id uuid,
  execution_proposal_version bigint,
  execution_approval_digest char(64),
  final_packet_payload jsonb,
  final_packet_canonical bytea,
  packet_digest_preimage_canonical bytea,
  packet_digest char(64),
  outcome_fact_id uuid,
  outcome_fact_digest char(64),
  finalized_at timestamptz,
  invalidation_reason ops.paid_packet_invalidation_reason,
  invalidation_evidence_digest char(64),
  invalidation_authority_kind ops.paid_packet_invalidation_authority_kind,
  invalidation_authority_id uuid,
  invalidation_authority_version bigint,
  invalidation_authority_digest char(64),
  invalidated_at timestamptz,
  packet_record_payload jsonb NOT NULL,
  packet_record_canonical bytea NOT NULL,
  packet_record_digest_preimage_canonical bytea NOT NULL,
  packet_record_digest char(64) NOT NULL,
  packet_audit_event_id uuid NOT NULL,
  packet_outbox_id uuid,
  outcome_audit_event_id uuid,
  outcome_outbox_id uuid,
  operation_receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_paid_evidence_packets_pkey PRIMARY KEY (packet_id, packet_version)
);
ALTER TABLE ops.paid_evidence_packets OWNER TO gurine_migrator;
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_record_digest_uq UNIQUE (packet_record_digest);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_record_binding_uq UNIQUE (packet_id, packet_version, packet_record_digest);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_subject_member_binding_uq UNIQUE (packet_id, packet_version, packet_subject_digest, member_set_digest);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_final_digest_binding_uq UNIQUE (packet_id, packet_version, packet_digest);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_reciprocal_outcome_binding_uq UNIQUE (packet_id, packet_version, packet_digest, organization_id, subject_kind, terminal_receipt_kind, terminal_receipt_id, terminal_receipt_version, terminal_receipt_digest, terminal_resulting_state, terminal_effective_at);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_operation_receipt_uq UNIQUE (operation_receipt_digest);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_outcome_uq UNIQUE (outcome_fact_id);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_version_ck CHECK (packet_version IN (1,2) AND qualification_episode_version > 0 AND commercial_contract_version > 0 AND review_snapshot_version > 0 AND member_count = 10);
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_sku_ck CHECK (sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1');
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_subject_shape_ck CHECK ((subject_kind = 'AUDITED_DELIVERY' AND num_nonnulls(subject_delivery_id,subject_rendering_digest,subject_authorization_snapshot_digest) = 3 AND num_nonnulls(decision_cycle_id,decision_cycle_version,decision_cycle_digest) = 0) OR (subject_kind = 'COMPLETED_DECISION_CYCLE' AND num_nonnulls(decision_cycle_id,decision_cycle_version,decision_cycle_digest) = 3 AND decision_cycle_version > 0 AND num_nonnulls(subject_delivery_id,subject_rendering_digest,subject_authorization_snapshot_digest) = 0));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_version_one_shape_ck CHECK (packet_version <> 1 OR (state = 'AWAITING_TERMINAL_BINDING' AND predecessor_packet_version IS NULL AND predecessor_packet_record_digest IS NULL AND num_nonnulls(terminal_receipt_kind,terminal_receipt_id,terminal_receipt_version,terminal_receipt_digest,terminal_resulting_state,terminal_applied,terminal_binding_digest,terminal_effective_at,delivery_receipt_id,delivery_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,delivery_applied,decision_receipt_id,decision_proposal_id,decision_proposal_version,decision_approval_digest,decision_receipt_digest,decision_actor_id,decision_kind,decision_conflict_snapshot_digest,execution_receipt_id,execution_id,execution_generation,execution_receipt_sequence,execution_receipt_digest,execution_receipt_kind,execution_aggregate_state,execution_mutates_aggregate_state,final_packet_payload,final_packet_canonical,packet_digest_preimage_canonical,packet_digest,outcome_fact_id,outcome_fact_digest,finalized_at,invalidation_reason,invalidation_evidence_digest,invalidated_at,outcome_audit_event_id,outcome_outbox_id) = 0 AND packet_outbox_id IS NOT NULL));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_version_two_chain_ck CHECK (packet_version <> 2 OR (predecessor_packet_version = 1 AND predecessor_packet_record_digest IS NOT NULL AND state IN ('FINALIZED','INVALIDATED')));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_finalized_shape_ck CHECK (state <> 'FINALIZED' OR (packet_version = 2 AND num_nonnulls(terminal_receipt_kind,terminal_receipt_id,terminal_receipt_version,terminal_receipt_digest,terminal_resulting_state,terminal_applied,terminal_binding_digest,terminal_effective_at,final_packet_payload,final_packet_canonical,packet_digest_preimage_canonical,packet_digest,outcome_fact_id,outcome_fact_digest,finalized_at,outcome_audit_event_id,outcome_outbox_id) = 17 AND terminal_applied = true AND packet_outbox_id IS NOT NULL AND num_nonnulls(invalidation_reason,invalidation_evidence_digest,invalidated_at) = 0 AND ((terminal_receipt_kind = 'OUTBOUND_DELIVERY' AND subject_kind = 'AUDITED_DELIVERY' AND terminal_resulting_state IN ('DELIVERED','READ') AND num_nonnulls(delivery_receipt_id,delivery_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,delivery_applied) = 6 AND delivery_id = subject_delivery_id AND delivery_receipt_id = terminal_receipt_id AND delivery_receipt_sequence = terminal_receipt_version AND delivery_receipt_digest = terminal_receipt_digest AND delivery_resulting_state = terminal_resulting_state::text AND delivery_applied = true AND num_nonnulls(decision_receipt_id,decision_proposal_id,decision_proposal_version,decision_approval_digest,decision_receipt_digest,decision_actor_id,decision_kind,decision_conflict_snapshot_digest,execution_receipt_id,execution_id,execution_generation,execution_receipt_sequence,execution_receipt_digest,execution_receipt_kind,execution_aggregate_state,execution_mutates_aggregate_state) = 0) OR (terminal_receipt_kind = 'ORGANIZATION_DECISION' AND subject_kind = 'COMPLETED_DECISION_CYCLE' AND terminal_resulting_state = 'REJECTED_FINAL' AND num_nonnulls(decision_receipt_id,decision_proposal_id,decision_proposal_version,decision_approval_digest,decision_receipt_digest,decision_actor_id,decision_kind,decision_conflict_snapshot_digest) = 8 AND decision_receipt_id = terminal_receipt_id AND decision_proposal_id = decision_cycle_id AND decision_proposal_version = terminal_receipt_version AND decision_proposal_version = decision_cycle_version AND decision_approval_digest = decision_cycle_digest AND decision_receipt_digest = terminal_receipt_digest AND decision_kind = 'REJECT' AND num_nonnulls(delivery_receipt_id,delivery_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,delivery_applied,execution_receipt_id,execution_id,execution_generation,execution_receipt_sequence,execution_receipt_digest,execution_receipt_kind,execution_aggregate_state,execution_mutates_aggregate_state) = 0) OR (terminal_receipt_kind = 'ORGANIZATION_DECISION' AND subject_kind = 'COMPLETED_DECISION_CYCLE' AND terminal_resulting_state = 'EFFECT_SUCCEEDED' AND num_nonnulls(execution_receipt_id,execution_id,execution_generation,execution_receipt_sequence,execution_receipt_digest,execution_receipt_kind,execution_aggregate_state,execution_mutates_aggregate_state) = 8 AND execution_receipt_id = terminal_receipt_id AND execution_receipt_sequence = terminal_receipt_version AND execution_receipt_digest = terminal_receipt_digest AND execution_receipt_kind = 'EFFECT_SUCCEEDED' AND execution_aggregate_state = 'SUCCEEDED' AND execution_mutates_aggregate_state = true AND num_nonnulls(delivery_receipt_id,delivery_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,delivery_applied,decision_receipt_id,decision_proposal_id,decision_proposal_version,decision_approval_digest,decision_receipt_digest,decision_actor_id,decision_kind,decision_conflict_snapshot_digest) = 0))));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_invalidated_shape_ck CHECK (state <> 'INVALIDATED' OR (packet_version = 2 AND num_nonnulls(invalidation_reason,invalidation_evidence_digest,invalidated_at) = 3 AND num_nonnulls(terminal_receipt_kind,terminal_receipt_id,terminal_receipt_version,terminal_receipt_digest,terminal_resulting_state,terminal_applied,terminal_binding_digest,terminal_effective_at,delivery_receipt_id,delivery_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,delivery_applied,decision_receipt_id,decision_proposal_id,decision_proposal_version,decision_approval_digest,decision_receipt_digest,decision_actor_id,decision_kind,decision_conflict_snapshot_digest,execution_receipt_id,execution_id,execution_generation,execution_receipt_sequence,execution_receipt_digest,execution_receipt_kind,execution_aggregate_state,execution_mutates_aggregate_state,final_packet_payload,final_packet_canonical,packet_digest_preimage_canonical,packet_digest,outcome_fact_id,outcome_fact_digest,finalized_at,outcome_audit_event_id,outcome_outbox_id) = 0 AND packet_outbox_id IS NULL));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_binding_event_shape_ck CHECK ((packet_version = 1 AND num_nonnulls(binding_source_event_id,binding_source_event_envelope_digest,binding_logical_consumer) = 0) OR (packet_version = 2 AND num_nonnulls(binding_source_event_id,binding_source_event_envelope_digest,binding_logical_consumer) = 3 AND length(btrim(binding_logical_consumer)) BETWEEN 1 AND 100));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_execution_cycle_shape_ck CHECK ((execution_receipt_id IS NULL AND num_nonnulls(execution_proposal_id,execution_proposal_version,execution_approval_digest) = 0) OR (execution_receipt_id IS NOT NULL AND num_nonnulls(execution_proposal_id,execution_proposal_version,execution_approval_digest) = 3 AND execution_proposal_id=decision_cycle_id AND execution_proposal_version=decision_cycle_version AND execution_approval_digest=decision_cycle_digest));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_terminal_time_proof_shape_ck CHECK ((terminal_receipt_kind IS NULL AND num_nonnulls(delivery_projection_disposition,delivery_resulting_proof_level,delivery_observed_at,decision_record_kind,decision_resulting_proposal_state,decision_decided_at,execution_observed_at)=0) OR (terminal_receipt_kind='OUTBOUND_DELIVERY' AND delivery_projection_disposition='APPLIED' AND delivery_resulting_proof_level=terminal_resulting_state::text AND delivery_observed_at=terminal_effective_at AND num_nonnulls(decision_record_kind,decision_resulting_proposal_state,decision_decided_at,execution_observed_at)=0) OR (terminal_receipt_kind='ORGANIZATION_DECISION' AND terminal_resulting_state='REJECTED_FINAL' AND decision_record_kind='DECISION' AND decision_resulting_proposal_state='REJECTED' AND decision_decided_at=terminal_effective_at AND num_nonnulls(delivery_projection_disposition,delivery_resulting_proof_level,delivery_observed_at,execution_observed_at)=0) OR (terminal_receipt_kind='ORGANIZATION_DECISION' AND terminal_resulting_state='EFFECT_SUCCEEDED' AND execution_observed_at=terminal_effective_at AND num_nonnulls(delivery_projection_disposition,delivery_resulting_proof_level,delivery_observed_at,decision_record_kind,decision_resulting_proposal_state,decision_decided_at)=0));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_invalidation_authority_shape_ck CHECK ((state = 'INVALIDATED' AND num_nonnulls(invalidation_authority_kind,invalidation_authority_id,invalidation_authority_version,invalidation_authority_digest) = 4 AND invalidation_authority_version > 0) OR (state <> 'INVALIDATED' AND num_nonnulls(invalidation_authority_kind,invalidation_authority_id,invalidation_authority_version,invalidation_authority_digest) = 0));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_digest_ck CHECK (qualification_episode_digest ~ '^[0-9a-f]{64}$' AND commercial_contract_digest ~ '^[0-9a-f]{64}$' AND review_snapshot_digest ~ '^[0-9a-f]{64}$' AND review_member_set_digest ~ '^[0-9a-f]{64}$' AND paid_member_manifest_digest ~ '^[0-9a-f]{64}$' AND source_event_envelope_digest ~ '^[0-9a-f]{64}$' AND packet_subject_digest ~ '^[0-9a-f]{64}$' AND member_set_digest ~ '^[0-9a-f]{64}$' AND operation_receipt_digest ~ '^[0-9a-f]{64}$' AND packet_record_digest ~ '^[0-9a-f]{64}$' AND (binding_source_event_envelope_digest IS NULL OR binding_source_event_envelope_digest ~ '^[0-9a-f]{64}$') AND (predecessor_packet_record_digest IS NULL OR predecessor_packet_record_digest ~ '^[0-9a-f]{64}$') AND (terminal_receipt_digest IS NULL OR terminal_receipt_digest ~ '^[0-9a-f]{64}$') AND (terminal_binding_digest IS NULL OR terminal_binding_digest ~ '^[0-9a-f]{64}$') AND (packet_digest IS NULL OR packet_digest ~ '^[0-9a-f]{64}$') AND (outcome_fact_digest IS NULL OR outcome_fact_digest ~ '^[0-9a-f]{64}$') AND (invalidation_evidence_digest IS NULL OR invalidation_evidence_digest ~ '^[0-9a-f]{64}$') AND (invalidation_authority_digest IS NULL OR invalidation_authority_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_canonical_ck CHECK (ops.paid_evidence_packet_subject_binding_v1_is_valid(subject_binding_payload) AND convert_from(subject_binding_canonical,'UTF8')::jsonb = subject_binding_payload AND ops.paid_evidence_packet_storage_record_v1_is_valid(packet_record_payload) AND convert_from(packet_record_canonical,'UTF8')::jsonb = packet_record_payload AND packet_record_digest = encode(extensions.digest(packet_record_digest_preimage_canonical,'sha256'),'hex') AND packet_record_payload->>'packetRecordDigest' = packet_record_digest AND (packet_digest IS NULL OR (ops.paid_evidence_packet_v1_is_valid(final_packet_payload) AND convert_from(final_packet_canonical,'UTF8')::jsonb = final_packet_payload AND packet_digest = encode(extensions.digest(packet_digest_preimage_canonical,'sha256'),'hex') AND final_packet_payload->>'packetDigest' = packet_digest)));
CREATE UNIQUE INDEX paid_packet_one_successor_uq ON ops.paid_evidence_packets USING btree (packet_id) WHERE packet_version = 2;
CREATE UNIQUE INDEX paid_packet_terminal_uq ON ops.paid_evidence_packets USING btree (terminal_receipt_kind, terminal_receipt_id, terminal_receipt_version, terminal_receipt_digest) WHERE state = 'FINALIZED';
CREATE UNIQUE INDEX paid_packet_subject_source_event_uq ON ops.paid_evidence_packets USING btree (source_event_id, source_event_envelope_digest) WHERE packet_version = 1;
CREATE UNIQUE INDEX paid_packet_delivery_subject_uq ON ops.paid_evidence_packets USING btree (subject_delivery_id) WHERE packet_version = 1 AND subject_kind = 'AUDITED_DELIVERY';
CREATE UNIQUE INDEX paid_packet_decision_subject_uq ON ops.paid_evidence_packets USING btree (decision_cycle_id, decision_cycle_version, decision_cycle_digest) WHERE packet_version = 1 AND subject_kind = 'COMPLETED_DECISION_CYCLE';
CREATE UNIQUE INDEX paid_packet_binding_inbox_uq ON ops.paid_evidence_packets USING btree (binding_logical_consumer, binding_source_event_id, binding_source_event_envelope_digest) WHERE packet_version = 2;
CREATE INDEX paid_packet_awaiting_idx ON ops.paid_evidence_packets USING btree (state, created_at, packet_id) WHERE state = 'AWAITING_TERMINAL_BINDING';
CREATE INDEX paid_packet_contract_idx ON ops.paid_evidence_packets USING btree (commercial_contract_id, commercial_contract_version, packet_version, packet_id);
CREATE INDEX paid_packet_qualification_idx ON ops.paid_evidence_packets USING btree (qualification_receipt_id, qualification_episode_version, packet_version, packet_id);
REVOKE ALL ON ops.paid_evidence_packets FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.paid_evidence_packets TO gurine_workflow_worker;
GRANT SELECT ON ops.paid_evidence_packets TO gurine_control_api;
GRANT SELECT ON ops.paid_evidence_packets TO gurine_auditor;
CREATE TABLE ops.paid_evidence_packet_members (
  packet_id uuid NOT NULL,
  packet_version bigint NOT NULL,
  packet_subject_digest char(64) NOT NULL,
  packet_member_set_digest char(64) NOT NULL,
  member_ordinal smallint NOT NULL,
  category ops.paid_evidence_member_category NOT NULL,
  source_set_id uuid NOT NULL,
  source_set_version bigint NOT NULL,
  source_set_digest char(64) NOT NULL,
  disposition_kind text,
  member_payload jsonb NOT NULL,
  member_canonical bytea NOT NULL,
  member_digest_preimage_canonical bytea NOT NULL,
  member_record_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ops_paid_evidence_packet_members_pkey PRIMARY KEY (packet_id, packet_version, member_ordinal)
);
ALTER TABLE ops.paid_evidence_packet_members OWNER TO gurine_migrator;
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_category_uq UNIQUE (packet_id, packet_version, category);
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_record_digest_uq UNIQUE (packet_id, packet_version, member_record_digest);
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_source_uq UNIQUE (packet_id, packet_version, category, source_set_id, source_set_version, source_set_digest);
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_version_ordinal_ck CHECK (packet_version = 1 AND member_ordinal BETWEEN 0 AND 9 AND source_set_version > 0);
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_category_ordinal_ck CHECK ((member_ordinal,category) IN ((0,'AUTHORIZED_DATASET_SNAPSHOT'),(1,'SOURCE_RIGHTS'),(2,'CAPABILITY_ACTIVATION'),(3,'EXTRACTION_AND_TRANSFORMATION_LINEAGE'),(4,'REPRODUCTION_AND_COMPARISON_INPUT'),(5,'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE'),(6,'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE'),(7,'AI_PROVENANCE_WHEN_CONTRIBUTED'),(8,'HUMAN_DECISION'),(9,'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED')));
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_disposition_ck CHECK ((category NOT IN ('AI_PROVENANCE_WHEN_CONTRIBUTED','INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED') AND disposition_kind IS NULL) OR (category = 'AI_PROVENANCE_WHEN_CONTRIBUTED' AND disposition_kind IN ('CONTRIBUTED','DID_NOT_CONTRIBUTE')) OR (category = 'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED' AND disposition_kind IN ('COMPLETED','POLICY_NOT_REQUIRED')));
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_digest_ck CHECK (packet_subject_digest ~ '^[0-9a-f]{64}$' AND packet_member_set_digest ~ '^[0-9a-f]{64}$' AND source_set_digest ~ '^[0-9a-f]{64}$' AND member_record_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_canonical_ck CHECK (ops.paid_evidence_packet_member_input_v1_is_valid(member_payload) AND convert_from(member_canonical,'UTF8')::jsonb = member_payload AND member_record_digest = encode(extensions.digest(member_digest_preimage_canonical,'sha256'),'hex'));
CREATE INDEX paid_packet_member_parent_idx ON ops.paid_evidence_packet_members USING btree (packet_id, packet_version, member_ordinal);
CREATE INDEX paid_packet_member_source_idx ON ops.paid_evidence_packet_members USING btree (source_set_id, source_set_version, source_set_digest, packet_id);
REVOKE ALL ON ops.paid_evidence_packet_members FROM PUBLIC, gurine_workflow_worker, gurine_control_api, gurine_auditor, gurine_public_projector, gurine_public_api, gurine_submission_api, gurine_ingest_worker, gurine_analysis_worker, gurine_notification_worker, gurine_scheduler, gurine_document_extractor, gurine_identity_api;
GRANT SELECT ON ops.paid_evidence_packet_members TO gurine_workflow_worker;
GRANT SELECT ON ops.paid_evidence_packet_members TO gurine_control_api;
GRANT SELECT ON ops.paid_evidence_packet_members TO gurine_auditor;
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_root_fk FOREIGN KEY (root_rate_id) REFERENCES ops.fx_rate_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.fx_rate_facts ADD CONSTRAINT fx_rate_supersedes_fk FOREIGN KEY (supersedes_rate_id) REFERENCES ops.fx_rate_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.tariff_versions ADD CONSTRAINT tariff_cost_allocation_period_fk FOREIGN KEY (cost_allocation_period_id, cost_allocation_row_kind) REFERENCES ops.cost_allocations (id, row_kind) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_tariff_fk FOREIGN KEY (tariff_version_id, deployment_id, sku, accounting_timezone) REFERENCES ops.tariff_versions (id, deployment_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_tariff_record_fk FOREIGN KEY (tariff_version_id, tariff_record_digest) REFERENCES ops.tariff_versions (id, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_qualification_fk FOREIGN KEY (qualification_receipt_id, deployment_id, organization_id, sku, qualification_episode_id, qualification_receipt_digest) REFERENCES ops.commercial_qualification_receipts (id, deployment_id, organization_id, sku, qualification_episode_id, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_root_fk FOREIGN KEY (root_contract_period_id) REFERENCES ops.commercial_contract_periods (id) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_contract_periods ADD CONSTRAINT contract_period_supersedes_fk FOREIGN KEY (supersedes_contract_period_id) REFERENCES ops.commercial_contract_periods (id) ON DELETE RESTRICT;
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_root_fk FOREIGN KEY (root_receipt_id) REFERENCES ops.usage_window_receipts (id) ON DELETE RESTRICT;
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_supersedes_fk FOREIGN KEY (supersedes_receipt_id) REFERENCES ops.usage_window_receipts (id) ON DELETE RESTRICT;
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_contract_fk FOREIGN KEY (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, contract_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.usage_window_receipts ADD CONSTRAINT usage_window_receipt_tariff_fk FOREIGN KEY (tariff_version_id, deployment_id, sku, accounting_timezone) REFERENCES ops.tariff_versions (id, deployment_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_root_fk FOREIGN KEY (root_usage_fact_id) REFERENCES ops.usage_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_supersedes_fk FOREIGN KEY (supersedes_usage_fact_id) REFERENCES ops.usage_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_contract_period_fk FOREIGN KEY (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, contract_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_tariff_fk FOREIGN KEY (tariff_version_id, deployment_id, sku, accounting_timezone) REFERENCES ops.tariff_versions (id, deployment_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.usage_facts ADD CONSTRAINT usage_fact_source_receipt_fk FOREIGN KEY (source_receipt_id, source_receipt_version, source_receipt_digest) REFERENCES ops.usage_window_receipts (id, receipt_version, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_contract_period_fk FOREIGN KEY (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, contract_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_tariff_fk FOREIGN KEY (tariff_version_id, deployment_id, sku, accounting_timezone) REFERENCES ops.tariff_versions (id, deployment_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_root_fk FOREIGN KEY (root_discount_id) REFERENCES ops.discount_decisions (id) ON DELETE RESTRICT;
ALTER TABLE ops.discount_decisions ADD CONSTRAINT discount_supersedes_fk FOREIGN KEY (supersedes_discount_id) REFERENCES ops.discount_decisions (id) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_root_fk FOREIGN KEY (root_invoice_id) REFERENCES ops.invoice_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_supersedes_fk FOREIGN KEY (supersedes_invoice_id, root_invoice_id, predecessor_reconciliation_digest) REFERENCES ops.invoice_facts (id, root_invoice_id, reconciliation_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_contract_period_fk FOREIGN KEY (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, contract_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_invoice_fk FOREIGN KEY (invoice_id, currency) REFERENCES ops.invoice_facts (id, currency) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_usage_fk FOREIGN KEY (usage_fact_id, usage_fact_digest) REFERENCES ops.usage_facts (id, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_tariff_fk FOREIGN KEY (tariff_version_id, tariff_record_digest) REFERENCES ops.tariff_versions (id, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_discount_fk FOREIGN KEY (discount_decision_id, discount_record_digest) REFERENCES ops.discount_decisions (id, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_line_facts ADD CONSTRAINT invoice_line_facts_corrected_line_fk FOREIGN KEY (corrects_line_id, invoice_id) REFERENCES ops.invoice_line_facts (id, invoice_id) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_root_fk FOREIGN KEY (root_membership_id, usage_root_fact_id) REFERENCES ops.invoice_usage_memberships (id, usage_root_fact_id) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_supersedes_fk FOREIGN KEY (supersedes_membership_id, root_membership_id, predecessor_invoice_id, predecessor_membership_digest) REFERENCES ops.invoice_usage_memberships (id, root_membership_id, invoice_id, membership_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_invoice_fk FOREIGN KEY (invoice_id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency) REFERENCES ops.invoice_facts (id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_usage_fk FOREIGN KEY (usage_fact_id, usage_root_fact_id, usage_fact_revision, usage_fact_digest) REFERENCES ops.usage_facts (id, root_usage_fact_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_receipt_fk FOREIGN KEY (usage_window_receipt_id, usage_window_receipt_version, usage_window_receipt_digest) REFERENCES ops.usage_window_receipts (id, receipt_version, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.invoice_usage_memberships ADD CONSTRAINT invoice_usage_memberships_line_fk FOREIGN KEY (invoice_line_id, invoice_id) REFERENCES ops.invoice_line_facts (id, invoice_id) ON DELETE RESTRICT;
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_contract_period_fk FOREIGN KEY (contract_period_id, deployment_id, organization_id, contract_id, sku, accounting_timezone) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, contract_id, sku, accounting_timezone) ON DELETE RESTRICT;
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_invoice_fk FOREIGN KEY (invoice_id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency) REFERENCES ops.invoice_facts (id, deployment_id, organization_id, contract_period_id, contract_id, sku, accounting_timezone, currency) ON DELETE RESTRICT;
ALTER TABLE ops.revenue_facts ADD CONSTRAINT revenue_facts_invoice_line_fk FOREIGN KEY (invoice_line_id, invoice_id, sku, currency) REFERENCES ops.invoice_line_facts (id, invoice_id, sku, currency) ON DELETE RESTRICT;
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_header_fk FOREIGN KEY (header_id) REFERENCES ops.funding_concentration_snapshots (id) ON DELETE RESTRICT;
ALTER TABLE ops.funding_concentration_snapshots ADD CONSTRAINT funding_snapshot_prior_header_fk FOREIGN KEY (prior_header_id) REFERENCES ops.funding_concentration_snapshots (id) ON DELETE RESTRICT;
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_snapshot_fk FOREIGN KEY (snapshot_header_id, snapshot_batch_id, snapshot_digest) REFERENCES ops.funding_concentration_snapshots (id, snapshot_batch_id, snapshot_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.funding_disclosure_revisions ADD CONSTRAINT funding_disclosure_prior_fk FOREIGN KEY (prior_revision_id, prior_disclosure_id, prior_revision, prior_revision_digest) REFERENCES editorial.funding_disclosure_revisions (id, disclosure_id, revision, revision_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.funding_disclosure_entries ADD CONSTRAINT funding_disclosure_entry_revision_fk FOREIGN KEY (revision_id, disclosure_id, revision) REFERENCES editorial.funding_disclosure_revisions (id, disclosure_id, revision) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_evaluation_fk FOREIGN KEY (evaluation_id) REFERENCES ops.sku_readiness_evaluations (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_contract_period_fk FOREIGN KEY (commercial_contract_period_id) REFERENCES ops.commercial_contract_periods (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_tariff_fk FOREIGN KEY (tariff_version_id) REFERENCES ops.tariff_versions (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_invoice_fk FOREIGN KEY (invoice_fact_id) REFERENCES ops.invoice_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_revenue_fk FOREIGN KEY (revenue_fact_id) REFERENCES ops.revenue_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_cost_allocation_fk FOREIGN KEY (cost_allocation_period_id, cost_allocation_row_kind) REFERENCES ops.cost_allocations (id, row_kind) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_outcome_fact_fk FOREIGN KEY (outcome_fact_id) REFERENCES ops.outcome_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.sku_readiness_items ADD CONSTRAINT sku_readiness_items_sli_contract_fk FOREIGN KEY (sli_contract_period_id, sli_organization_id, sli_policy_digest) REFERENCES ops.commercial_contract_periods (id, organization_id, sla_policy_digest) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_root_fk FOREIGN KEY (root_correction_id) REFERENCES ops.accounting_corrections (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_supersedes_fk FOREIGN KEY (supersedes_correction_id) REFERENCES ops.accounting_corrections (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_reverses_fk FOREIGN KEY (reverses_correction_id) REFERENCES ops.accounting_corrections (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_cost_allocation_fk FOREIGN KEY (target_cost_allocation_id) REFERENCES ops.cost_allocations (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_invoice_fact_fk FOREIGN KEY (target_invoice_fact_id) REFERENCES ops.invoice_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_invoice_line_fact_fk FOREIGN KEY (target_invoice_line_fact_id) REFERENCES ops.invoice_line_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.accounting_corrections ADD CONSTRAINT accounting_correction_revenue_fact_fk FOREIGN KEY (target_revenue_fact_id) REFERENCES ops.revenue_facts (id) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_root_fk FOREIGN KEY (root_receipt_id) REFERENCES ops.commercial_qualification_receipts (id) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_supersedes_fk FOREIGN KEY (supersedes_receipt_id) REFERENCES ops.commercial_qualification_receipts (id) ON DELETE RESTRICT;
ALTER TABLE ops.commercial_qualification_receipts ADD CONSTRAINT commercial_qualification_acquisition_fk FOREIGN KEY (acquisition_source_receipt_id, acquisition_source_receipt_digest) REFERENCES ops.acquisition_source_receipts (id, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.offer_profile_capabilities ADD CONSTRAINT offer_profile_capability_parent_fk FOREIGN KEY (contract_period_id, offer_profile_id, offer_profile_version, offer_profile_digest, offer_capability_set_digest, offer_quota_set_digest, offer_overage_policy_set_digest, offer_service_credit_policy_digest) REFERENCES ops.commercial_contract_periods (id, offer_profile_id, offer_profile_version, offer_profile_digest, offer_capability_set_digest, offer_quota_set_digest, offer_overage_policy_set_digest, offer_service_credit_policy_digest) ON DELETE RESTRICT;
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_predecessor_fk FOREIGN KEY (packet_id, predecessor_packet_version, predecessor_packet_record_digest) REFERENCES ops.paid_evidence_packets (packet_id, packet_version, packet_record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_qualification_fk FOREIGN KEY (qualification_receipt_id, deployment_id, organization_id, sku, qualification_episode_id, qualification_episode_version, qualification_episode_digest) REFERENCES ops.commercial_qualification_receipts (id, deployment_id, organization_id, sku, qualification_episode_id, revision, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_contract_fk FOREIGN KEY (commercial_contract_id, deployment_id, organization_id, sku, commercial_contract_version, commercial_contract_digest) REFERENCES ops.commercial_contract_periods (id, deployment_id, organization_id, sku, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.paid_evidence_packets ADD CONSTRAINT paid_packet_outcome_fk FOREIGN KEY (outcome_fact_id, outcome_fact_digest, organization_id, subject_kind, terminal_receipt_id, terminal_receipt_version, terminal_receipt_digest, terminal_receipt_kind, terminal_resulting_state, terminal_effective_at, packet_id, packet_version, packet_digest) REFERENCES ops.outcome_facts (id, fact_digest, organization_id, paid_subject_kind, terminal_receipt_id, terminal_receipt_version, terminal_receipt_digest, paid_terminal_receipt_kind, paid_terminal_resulting_state, effective_from, paid_packet_id, paid_packet_version, paid_packet_digest) ON DELETE RESTRICT;
ALTER TABLE ops.paid_evidence_packet_members ADD CONSTRAINT paid_packet_member_parent_fk FOREIGN KEY (packet_id, packet_version, packet_subject_digest, packet_member_set_digest) REFERENCES ops.paid_evidence_packets (packet_id, packet_version, packet_subject_digest, member_set_digest) ON DELETE RESTRICT;
CREATE OR REPLACE FUNCTION ops.read_invoice_membership_v1(
  p_contract_period_id uuid, p_expected_contract_record_digest char(64),
  p_period_start date, p_period_end date, p_billing_cutoff_at timestamptz)
RETURNS SETOF ops.invoice_membership_read_row_v1
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  SELECT u.root_usage_fact_id, u.id, u.record_digest, u.meter_kind,
         u.period_start, u.period_end, u.measurement_state,
         m.membership_kind, m.invoice_id, m.membership_digest,
         CASE
           WHEN m.id IS NULL THEN 'MISSING_MEMBERSHIP'
           WHEN u.measurement_state <> 'COMPLETE' THEN 'USAGE_NOT_COMPLETE'
           WHEN m.measurement_state <> u.measurement_state THEN 'MEASUREMENT_STATE_MISMATCH'
           ELSE NULL
         END
  FROM ops.usage_facts u
  LEFT JOIN LATERAL (
    SELECT im.* FROM ops.invoice_usage_memberships im
    WHERE im.usage_fact_id = u.id
      AND im.membership_effect <> 'RESTATEMENT'
      AND im.recorded_at <= p_billing_cutoff_at
    ORDER BY im.revision DESC, im.id DESC LIMIT 1
  ) m ON TRUE
  WHERE u.contract_period_id = p_contract_period_id
    AND u.period_start < p_period_end AND u.period_end > p_period_start
    AND u.record_digest IS NOT NULL
    AND u.created_at <= p_billing_cutoff_at;
$$;
REVOKE ALL ON FUNCTION ops.read_invoice_membership_v1(uuid, char(64), date, date, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_invoice_membership_v1(uuid, char(64), date, date, timestamptz) TO gurine_workflow_worker, gurine_control_api, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.read_cac_metric_inputs_v1(
  p_period_start date, p_period_end date, p_reporting_currency char(3),
  p_expected_accounting_policy_digest char(64))
RETURNS TABLE(
  organization_id uuid, acquisition_amount numeric(24,6), attribution_state text,
  acquisition_source_receipt_digest char(64), input_set_digest char(64),
  metric_status text, reason_code text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  WITH lines AS (
    SELECT ca.organization_id, ca.allocated_amount, ca.acquisition_attribution_state::text AS attribution_state,
           ca.acquisition_source_receipt_digest, ca.record_digest
    FROM ops.cost_allocations ca
    WHERE ca.row_kind = 'LINE' AND ca.cost_category = 'SALES_CUSTOMER_ACQUISITION'
      AND ca.period_start < p_period_end AND ca.period_end > p_period_start
      AND ca.currency = p_reporting_currency
      AND ca.accounting_policy_digest = p_expected_accounting_policy_digest
  ), aggregate AS (
    SELECT COALESCE(bool_and(attribution_state = 'ATTRIBUTED' AND organization_id IS NOT NULL
                              AND acquisition_source_receipt_digest IS NOT NULL), false) AS complete,
           COALESCE(sum(allocated_amount), 0)::numeric(24,6) AS total_amount,
           encode(extensions.digest(convert_to(COALESCE(string_agg(record_digest, ',' ORDER BY record_digest), ''), 'UTF8'),'sha256'),'hex')::char(64) AS input_digest
    FROM lines
  )
  SELECT l.organization_id, l.allocated_amount::numeric(24,6), l.attribution_state,
         l.acquisition_source_receipt_digest, a.input_digest,
         CASE WHEN a.complete THEN 'KNOWN' ELSE 'UNKNOWN' END,
         CASE WHEN a.complete THEN 'NONE' ELSE 'ATTRIBUTION_UNKNOWN' END
  FROM lines l CROSS JOIN aggregate a;
$$;
REVOKE ALL ON FUNCTION ops.read_cac_metric_inputs_v1(date, date, char(3), char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_cac_metric_inputs_v1(date, date, char(3), char(64)) TO gurine_workflow_worker, gurine_control_api, gurine_auditor;

COMMIT;
