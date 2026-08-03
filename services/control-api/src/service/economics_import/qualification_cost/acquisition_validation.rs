use super::*;

impl EconomicsAcquisitionSourceImportV1 {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        if self.evidence_segment_id.is_nil()
            || !valid_optional_uuid(&self.existing_receipt_id)
            || !valid_optional_uuid(&self.expected_head_id)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let valid = match self.resolution {
            EconomicsSourceResolutionV1::Existing => self.valid_existing(),
            EconomicsSourceResolutionV1::Append => self.valid_append()?,
        };
        valid.then_some(()).ok_or(ServiceError::InvalidRequest)
    }

    fn valid_existing(&self) -> bool {
        self.append_value.is_none()
            && matches!(
                (
                    self.existing_receipt_id.as_option().as_ref(),
                    self.existing_receipt_revision.as_option().as_ref(),
                    self.existing_receipt_digest.as_option().as_ref(),
                    self.expected_head_id.as_option().as_ref(),
                    self.expected_head_revision.as_option().as_ref(),
                    self.expected_head_digest.as_option().as_ref(),
                ),
                (Some(id), Some(revision), Some(digest), Some(head_id), Some(head_revision), Some(head_digest))
                    if *revision > 0
                        && id == head_id
                        && revision == head_revision
                        && digest == head_digest
            )
    }

    fn valid_append(&self) -> Result<bool, ServiceError> {
        if self.existing_receipt_id.is_some()
            || self.existing_receipt_revision.is_some()
            || self.existing_receipt_digest.is_some()
        {
            return Ok(false);
        }
        let Some(append) = self.append_value.as_option().as_ref() else {
            return Ok(false);
        };
        if append.source_signature_digest != self.source_signature_digest
            || !append.valid_common()?
        {
            return Ok(false);
        }
        Ok(match append.receipt_effect {
            AcquisitionSourceReceiptEffect::Original => {
                append.revision == 1
                    && append.root_receipt_id.is_none()
                    && append.supersedes_receipt_id.is_none()
                    && append.predecessor_receipt_digest.is_none()
                    && head_fence_is_absent(
                        &self.expected_head_id,
                        &self.expected_head_revision,
                        &self.expected_head_digest,
                    )
            }
            AcquisitionSourceReceiptEffect::Replacement
            | AcquisitionSourceReceiptEffect::Reversal => matches!(
                (
                    append.root_receipt_id.as_option().as_ref(),
                    append.supersedes_receipt_id.as_option().as_ref(),
                    append.predecessor_receipt_digest.as_option().as_ref(),
                    self.expected_head_id.as_option().as_ref(),
                    self.expected_head_revision.as_option().as_ref(),
                    self.expected_head_digest.as_option().as_ref(),
                ),
                (Some(_), Some(supersedes), Some(predecessor), Some(head_id), Some(head_revision), Some(head_digest))
                    if append.revision > 1
                        && supersedes == head_id
                        && predecessor == head_digest
                        && head_revision.checked_add(1) == Some(append.revision)
            ),
        })
    }
}

impl AcquisitionSourceReceiptInputV1 {
    fn valid_common(&self) -> Result<bool, ServiceError> {
        let valid_interval = parse_datetime(&self.valid_from)? < parse_datetime(&self.valid_until)?
            && parse_datetime(&self.valid_from)? <= parse_datetime(&self.attributed_at)?
            && parse_datetime(&self.attributed_at)? < parse_datetime(&self.valid_until)?;
        Ok(!self.deployment_id.is_nil()
            && !self.organization_id.is_nil()
            && self.revision > 0
            && valid_source_system_id(&self.source_system_id)
            && valid_bounded_text(&self.source_record_hmac_key_version, 100)
            && valid_bounded_text(&self.attribution_model_version, 128)
            && valid_optional_uuid(&self.root_receipt_id)
            && valid_optional_uuid(&self.supersedes_receipt_id)
            && valid_interval)
    }
}
