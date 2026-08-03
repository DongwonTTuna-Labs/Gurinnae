use super::*;

impl OfferCapabilityCode {
    const fn index(self) -> usize {
        match self {
            Self::PublicWeb => 0,
            Self::VerifiedEmail => 1,
            Self::ApiExport => 2,
            Self::SignedWebhook => 3,
            Self::DailyDigest => 4,
            Self::WeeklyDigest => 5,
            Self::Sms => 6,
            Self::Telegram => 7,
            Self::Whatsapp => 8,
            Self::Line => 9,
            Self::Kakao => 10,
            Self::Voice => 11,
        }
    }
}

impl EconomicsOfferCapabilityImportV1 {
    fn validate(&self, expected_index: usize) -> bool {
        if self.capability_code.index() != expected_index
            || self.capability_ordinal != (expected_index + 1) as i16
        {
            return false;
        }
        if matches!(self.offer_state, OfferCapabilityState::NotOffered) {
            return matches!(self.quota_kind, OfferQuotaKind::NotMetered)
                && self.included_quantity.as_option().is_none()
                && matches!(self.overage_policy, OfferOveragePolicy::NotApplicable)
                && self.overage_unit_price.as_option().is_none()
                && self.activation_policy_digest.as_option().is_none()
                && self.consent_policy_digest.as_option().is_none()
                && self.cost_policy_digest.as_option().is_none();
        }
        match self.capability_code {
            OfferCapabilityCode::PublicWeb => self.not_metered_shape(),
            OfferCapabilityCode::ApiExport => self.api_export_shape(),
            OfferCapabilityCode::SignedWebhook => {
                self.hard_limit_shape(OfferQuotaKind::WebhookDispatch)
            }
            OfferCapabilityCode::DailyDigest | OfferCapabilityCode::WeeklyDigest => {
                self.hard_limit_shape(OfferQuotaKind::DigestDispatch)
            }
            _ => self.hard_limit_shape(OfferQuotaKind::DeliveryAttempt),
        }
    }

    fn not_metered_shape(&self) -> bool {
        matches!(self.quota_kind, OfferQuotaKind::NotMetered)
            && self.included_quantity.as_option().is_none()
            && matches!(self.overage_policy, OfferOveragePolicy::NotApplicable)
            && self.overage_unit_price.as_option().is_none()
    }

    fn api_export_shape(&self) -> bool {
        if !matches!(self.quota_kind, OfferQuotaKind::ApiRecordUnit)
            || !self
                .included_quantity
                .as_option()
                .as_ref()
                .is_some_and(|value| *value >= Decimal::ZERO)
        {
            return false;
        }
        match (
            self.overage_policy,
            self.overage_unit_price.as_option().as_ref(),
        ) {
            (OfferOveragePolicy::DeclaredTariffOverage, Some(value)) => *value >= Decimal::ZERO,
            (OfferOveragePolicy::HardLimitNoOverage, None) => true,
            _ => false,
        }
    }

    fn hard_limit_shape(&self, quota_kind: OfferQuotaKind) -> bool {
        self.quota_kind == quota_kind
            && self
                .included_quantity
                .as_option()
                .as_ref()
                .is_some_and(|value| *value >= Decimal::ZERO)
            && matches!(self.overage_policy, OfferOveragePolicy::HardLimitNoOverage)
            && self.overage_unit_price.as_option().is_none()
    }
}

impl EconomicsContractImportV1 {
    pub(in super::super::super) fn validate(&self) -> Result<(), ServiceError> {
        if !self.identity_interval_shape()
            || !self.chain_and_head_shape()
            || !self.provisioning_and_sla_shape()
            || !self.capability_set_shape()
            || !self.required_digests_are_bound()
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }

    fn identity_interval_shape(&self) -> bool {
        let ids = [
            self.deployment_id,
            self.organization_id,
            self.contract_id,
            self.root_contract_period_id,
            self.tariff_version_id,
            self.qualification_receipt_id,
            self.qualification_episode_id,
            self.offer_profile_id,
        ];
        ids.iter().all(|id| !id.is_nil())
            && self.revision > 0
            && self.offer_profile_version > 0
            && self.period_start < self.period_end
            && datetime_before(&self.offer_effective_from, &self.offer_effective_until)
            && currency_shape(&self.currency)
            && text_len(&self.accounting_timezone, 1, 63)
            && text_len(&self.contract_reference_hmac_key_version, 1, 100)
            && self.binding_committed_amount >= Decimal::ZERO
            && matches!(self.sku, CommercialSku::EvidenceWorkspaceOrganizationV1)
            && matches!(
                self.stage,
                TariffStage::Pilot | TariffStage::GeneralAvailability
            )
    }

    fn chain_and_head_shape(&self) -> bool {
        let chain_matches = match self.fact_effect {
            CommercialPeriodFactEffect::Original => {
                self.revision == 1
                    && self.supersedes_contract_period_id.as_option().is_none()
                    && self.predecessor_record_digest.as_option().is_none()
                    && self.expected_head_id.as_option().is_none()
                    && self.expected_head_revision.as_option().is_none()
                    && self.expected_head_digest.as_option().is_none()
            }
            CommercialPeriodFactEffect::Replacement => {
                self.revision > 1
                    && self
                        .supersedes_contract_period_id
                        .as_option()
                        .as_ref()
                        .is_some_and(|id| !id.is_nil())
                    && self.predecessor_record_digest.as_option().is_some()
                    && self.expected_head_id.as_option()
                        == self.supersedes_contract_period_id.as_option()
                    && self.expected_head_revision.as_option().as_ref()
                        == Some(&(self.revision - 1))
                    && self.expected_head_digest.as_option()
                        == self.predecessor_record_digest.as_option()
            }
        };
        chain_matches && self.collection_failure_fence_shape()
    }

    fn collection_failure_fence_shape(&self) -> bool {
        match (
            self.collection_failure_task_id.as_option().as_ref(),
            self.collection_failure_task_version.as_option().as_ref(),
            self.collection_failure_task_digest.as_option().as_ref(),
        ) {
            (None, None, None) => true,
            (Some(task_id), Some(version), Some(_)) => {
                !task_id.is_nil()
                    && *version > 0
                    && matches!(self.fact_effect, CommercialPeriodFactEffect::Replacement)
                    && !matches!(self.status, CommercialContractStatus::Active)
            }
            _ => false,
        }
    }

    fn provisioning_and_sla_shape(&self) -> bool {
        let provisioning_valid = match self.provisioning_state {
            CommercialProvisioningState::Unprovisioned => self.provisioned_at.as_option().is_none(),
            CommercialProvisioningState::Provisioned => self
                .provisioned_at
                .as_option()
                .as_ref()
                .is_some_and(|value| datetime_not_before(value, &self.signed_at)),
        };
        let state_time_valid = datetime_not_before(&self.state_effective_at, &self.signed_at)
            && self
                .provisioned_at
                .as_option()
                .as_ref()
                .is_none_or(|value| datetime_not_before(&self.state_effective_at, value));
        provisioning_valid && state_time_valid && self.sla_selection_shape()
    }

    fn sla_selection_shape(&self) -> bool {
        let all_absent = self.sla_policy_version.as_option().is_none()
            && self.sla_policy_digest.as_option().is_none()
            && self.sla_target_availability_ratio.as_option().is_none()
            && self.sla_capability_set_digest.as_option().is_none()
            && self.sla_exclusion_schedule_digest.as_option().is_none()
            && self
                .sla_service_credit_schedule_digest
                .as_option()
                .is_none()
            && self.sla_measurement_policy_digest.as_option().is_none();
        match self.sla_selection_state {
            SlaSelectionState::UnavailableNotSold | SlaSelectionState::AvailableNotSelected => {
                !self.sla_add_on_selected && all_absent
            }
            SlaSelectionState::Selected => {
                self.sla_add_on_selected
                    && self
                        .sla_policy_version
                        .as_option()
                        .as_deref()
                        .is_some_and(|value| text_len(value, 1, 100))
                    && self
                        .sla_target_availability_ratio
                        .as_option()
                        .as_ref()
                        .is_some_and(|value| valid_ratio(*value))
                    && self.sla_policy_digest.as_option().is_some()
                    && self.sla_capability_set_digest.as_option().is_some()
                    && self.sla_exclusion_schedule_digest.as_option().is_some()
                    && self
                        .sla_service_credit_schedule_digest
                        .as_option()
                        .is_some()
                    && self.sla_measurement_policy_digest.as_option().is_some()
            }
        }
    }

    fn capability_set_shape(&self) -> bool {
        if self.capabilities.len() != 12 {
            return false;
        }
        let mut seen = [false; 12];
        for (index, capability) in self.capabilities.iter().enumerate() {
            let code_index = capability.capability_code.index();
            if code_index != index || seen[code_index] || !capability.validate(index) {
                return false;
            }
            seen[code_index] = true;
        }
        seen.into_iter().all(|value| value)
    }

    fn required_digests_are_bound(&self) -> bool {
        let values = [
            &self.contract_reference_hmac,
            &self.tariff_record_digest,
            &self.qualification_receipt_digest,
            &self.offer_contract_binding_digest,
            &self.offer_profile_digest,
            &self.offer_capability_set_digest,
            &self.offer_quota_set_digest,
            &self.offer_overage_policy_set_digest,
            &self.offer_service_credit_policy_digest,
            &self.offer_source_receipt_digest,
            &self.offer_signature_digest,
            &self.accounting_policy_digest,
            &self.commitment_policy_digest,
            &self.deployment_configuration_digest,
            &self.authority_reference_digest,
            &self.source_receipt_digest,
            &self.signature_digest,
        ];
        values.iter().all(|digest| digest.as_str().len() == 64)
    }
}

fn text_len(value: &str, minimum: usize, maximum: usize) -> bool {
    (minimum..=maximum).contains(&value.trim().chars().count())
}

fn currency_shape(value: &str) -> bool {
    value.len() == 3 && value.bytes().all(|byte| byte.is_ascii_uppercase())
}

fn valid_ratio(value: Decimal) -> bool {
    value > Decimal::ZERO && value <= Decimal::ONE
}

fn datetime_before(left: &DateTimeText, right: &DateTimeText) -> bool {
    datetime_order(left, right).is_some_and(|ordering| ordering.is_lt())
}

fn datetime_not_before(left: &DateTimeText, right: &DateTimeText) -> bool {
    datetime_order(left, right).is_some_and(|ordering| !ordering.is_lt())
}

fn datetime_order(left: &DateTimeText, right: &DateTimeText) -> Option<std::cmp::Ordering> {
    let left = OffsetDateTime::parse(left.as_str(), &Rfc3339).ok()?;
    let right = OffsetDateTime::parse(right.as_str(), &Rfc3339).ok()?;
    Some(left.cmp(&right))
}
