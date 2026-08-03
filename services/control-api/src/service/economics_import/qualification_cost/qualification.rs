use super::*;

#[path = "acquisition_validation.rs"]
mod acquisition_validation;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum QualificationReceiptEffect {
    Original,
    Replacement,
    Reversal,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
enum CommercialSku {
    #[serde(rename = "EVIDENCE_WORKSPACE_ORGANIZATION_V1")]
    EvidenceWorkspaceOrganizationV1,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum QualificationReason {
    QualificationAccepted,
    SourceCorrection,
    SourceReversal,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum AcquisitionSourceReceiptEffect {
    Original,
    Replacement,
    Reversal,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum AcquisitionSourceKind {
    OrganicSearch,
    Referral,
    Direct,
    Partner,
    Event,
    PaidSearch,
    PaidSocial,
    Content,
    Outbound,
    OtherReviewed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AcquisitionSourceReceiptInputV1 {
    root_receipt_id: RequiredNullable<Uuid>,
    revision: i64,
    receipt_effect: AcquisitionSourceReceiptEffect,
    supersedes_receipt_id: RequiredNullable<Uuid>,
    predecessor_receipt_digest: RequiredNullable<Sha256Digest>,
    deployment_id: Uuid,
    organization_id: Uuid,
    source_kind: AcquisitionSourceKind,
    source_system_id: String,
    source_record_identity_hmac: Sha256Digest,
    source_record_hmac_key_version: String,
    acquisition_campaign_digest: Sha256Digest,
    organization_binding_digest: Sha256Digest,
    attribution_model_version: String,
    attribution_model_digest: Sha256Digest,
    touchpoint_set_digest: Sha256Digest,
    source_record_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    valid_from: DateTimeText,
    valid_until: DateTimeText,
    attributed_at: DateTimeText,
    receipt_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsAcquisitionSourceImportV1 {
    resolution: EconomicsSourceResolutionV1,
    existing_receipt_id: RequiredNullable<Uuid>,
    existing_receipt_revision: RequiredNullable<i64>,
    existing_receipt_digest: RequiredNullable<Sha256Digest>,
    append_value: RequiredNullable<AcquisitionSourceReceiptInputV1>,
    evidence_segment_id: Uuid,
    evidence_segment_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsQualificationImportV1 {
    root_receipt_id: Uuid,
    revision: i64,
    receipt_effect: QualificationReceiptEffect,
    supersedes_receipt_id: RequiredNullable<Uuid>,
    predecessor_receipt_digest: RequiredNullable<Sha256Digest>,
    qualification_episode_id: Uuid,
    deployment_id: Uuid,
    organization_id: Uuid,
    sku: CommercialSku,
    decision_effective_at: DateTimeText,
    first_qualified_at: DateTimeText,
    recurring_job_attested: bool,
    authorized_data_identified: bool,
    authorized_data_feasible: bool,
    economic_buyer_role_bound: bool,
    operational_owner_role_bound: bool,
    independent_reviewer_role_bound: bool,
    source_rights_owner_role_bound: bool,
    incident_support_owner_role_bound: bool,
    pilot_scope_accepted: bool,
    success_metric_accepted: bool,
    budget_authority_accepted: bool,
    support_expectation_accepted: bool,
    trust_terms_accepted: bool,
    role_binding_hmac_key_version: String,
    economic_buyer_primary_role_binding_hmac: Sha256Digest,
    economic_buyer_backup_role_binding_hmac: Sha256Digest,
    operational_owner_primary_role_binding_hmac: Sha256Digest,
    operational_owner_backup_role_binding_hmac: Sha256Digest,
    independent_reviewer_primary_role_binding_hmac: Sha256Digest,
    independent_reviewer_backup_role_binding_hmac: Sha256Digest,
    source_rights_owner_primary_role_binding_hmac: Sha256Digest,
    source_rights_owner_backup_role_binding_hmac: Sha256Digest,
    incident_support_owner_primary_role_binding_hmac: Sha256Digest,
    incident_support_owner_backup_role_binding_hmac: Sha256Digest,
    source_system_id: String,
    source_record_identity_hmac: Sha256Digest,
    acquisition_source_receipt_id: RequiredNullable<Uuid>,
    acquisition_source_receipt_digest: RequiredNullable<Sha256Digest>,
    source_signature_digest: Sha256Digest,
    qualification_policy_version: i64,
    qualification_policy_digest: Sha256Digest,
    criterion_set_digest: Sha256Digest,
    role_binding_set_digest: Sha256Digest,
    evidence_set_digest: Sha256Digest,
    reason_code: QualificationReason,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
    acquisition_source: EconomicsAcquisitionSourceImportV1,
}

impl EconomicsQualificationImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        let required_ids = [
            self.root_receipt_id,
            self.qualification_episode_id,
            self.deployment_id,
            self.organization_id,
        ];
        if required_ids.iter().any(Uuid::is_nil)
            || self.qualification_policy_version < 1
            || !valid_source_system_id(&self.source_system_id)
            || !valid_bounded_text(&self.role_binding_hmac_key_version, 100)
            || !valid_optional_uuid(&self.acquisition_source_receipt_id)
            || (self.acquisition_source_receipt_id.is_some()
                != self.acquisition_source_receipt_digest.is_some())
            || !valid_optional_uuid(&self.supersedes_receipt_id)
            || !valid_optional_uuid(&self.expected_head_id)
            || self.acquisition_source.validate().is_err()
            || !self.valid_acquisition_source_link()
            || !valid_time_order(self)?
            || self.economic_buyer_primary_role_binding_hmac
                == self.economic_buyer_backup_role_binding_hmac
            || self.operational_owner_primary_role_binding_hmac
                == self.operational_owner_backup_role_binding_hmac
            || self.independent_reviewer_primary_role_binding_hmac
                == self.independent_reviewer_backup_role_binding_hmac
            || self.source_rights_owner_primary_role_binding_hmac
                == self.source_rights_owner_backup_role_binding_hmac
            || self.incident_support_owner_primary_role_binding_hmac
                == self.incident_support_owner_backup_role_binding_hmac
        {
            return Err(ServiceError::InvalidRequest);
        }
        let criteria = self.criteria();
        let all_criteria = criteria.into_iter().all(|value| value);
        let any_criteria = criteria.into_iter().any(|value| value);
        let valid = match self.receipt_effect {
            QualificationReceiptEffect::Original => {
                self.revision == 1
                    && self.supersedes_receipt_id.is_none()
                    && self.predecessor_receipt_digest.is_none()
                    && self.reason_code == QualificationReason::QualificationAccepted
                    && all_criteria
                    && same_instant(&self.first_qualified_at, &self.decision_effective_at)?
                    && head_fence_is_absent(
                        &self.expected_head_id,
                        &self.expected_head_revision,
                        &self.expected_head_digest,
                    )
            }
            QualificationReceiptEffect::Replacement => {
                self.successor_chain_is_valid(QualificationReason::SourceCorrection) && all_criteria
            }
            QualificationReceiptEffect::Reversal => {
                self.successor_chain_is_valid(QualificationReason::SourceReversal) && !any_criteria
            }
        };
        valid.then_some(()).ok_or(ServiceError::InvalidRequest)
    }

    fn valid_acquisition_source_link(&self) -> bool {
        match self.acquisition_source.resolution {
            EconomicsSourceResolutionV1::Append => {
                self.acquisition_source_receipt_id.is_none()
                    && self.acquisition_source_receipt_digest.is_none()
            }
            EconomicsSourceResolutionV1::Existing => matches!(
                (
                    self.acquisition_source_receipt_id.as_option().as_ref(),
                    self.acquisition_source_receipt_digest.as_option().as_ref(),
                    self.acquisition_source
                        .existing_receipt_id
                        .as_option()
                        .as_ref(),
                    self.acquisition_source
                        .existing_receipt_digest
                        .as_option()
                        .as_ref(),
                ),
                (Some(id), Some(digest), Some(existing_id), Some(existing_digest))
                    if id == existing_id && digest == existing_digest
            ),
        }
    }

    fn criteria(&self) -> [bool; 13] {
        [
            self.recurring_job_attested,
            self.authorized_data_identified,
            self.authorized_data_feasible,
            self.economic_buyer_role_bound,
            self.operational_owner_role_bound,
            self.independent_reviewer_role_bound,
            self.source_rights_owner_role_bound,
            self.incident_support_owner_role_bound,
            self.pilot_scope_accepted,
            self.success_metric_accepted,
            self.budget_authority_accepted,
            self.support_expectation_accepted,
            self.trust_terms_accepted,
        ]
    }

    fn successor_chain_is_valid(&self, reason: QualificationReason) -> bool {
        self.revision > 1
            && self.reason_code == reason
            && matches!(
                (
                    self.supersedes_receipt_id.as_option().as_ref(),
                    self.predecessor_receipt_digest.as_option().as_ref(),
                    self.expected_head_id.as_option().as_ref(),
                    self.expected_head_revision.as_option().as_ref(),
                    self.expected_head_digest.as_option().as_ref(),
                ),
                (Some(supersedes), Some(predecessor), Some(head_id), Some(head_revision), Some(head_digest))
                    if supersedes == head_id
                        && head_revision.checked_add(1) == Some(self.revision)
                        && predecessor == head_digest
            )
    }
}

fn valid_time_order(value: &EconomicsQualificationImportV1) -> Result<bool, ServiceError> {
    let first = parse_datetime(&value.first_qualified_at)?;
    let decision = parse_datetime(&value.decision_effective_at)?;
    Ok(first <= decision)
}

fn same_instant(left: &DateTimeText, right: &DateTimeText) -> Result<bool, ServiceError> {
    Ok(parse_datetime(left)? == parse_datetime(right)?)
}

fn parse_datetime(value: &DateTimeText) -> Result<OffsetDateTime, ServiceError> {
    OffsetDateTime::parse(value.as_str(), &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
}

fn head_fence_is_absent(
    id: &RequiredNullable<Uuid>,
    revision: &RequiredNullable<i64>,
    digest: &RequiredNullable<Sha256Digest>,
) -> bool {
    id.is_none() && revision.is_none() && digest.is_none()
}

fn valid_optional_uuid(value: &RequiredNullable<Uuid>) -> bool {
    value.as_option().is_none_or(|id| !id.is_nil())
}

fn valid_source_system_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes
            .first()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        && bytes.iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn valid_bounded_text(value: &str, max: usize) -> bool {
    value == value.trim() && (1..=max).contains(&value.len())
}
