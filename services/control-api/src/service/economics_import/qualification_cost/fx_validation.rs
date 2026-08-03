use super::*;

impl EconomicsFxRateSourceImportV1 {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        if self.evidence_segment_id.is_nil()
            || !valid_optional_uuid(&self.existing_rate_id)
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
                    self.existing_rate_id.as_option().as_ref(),
                    self.existing_rate_revision.as_option().as_ref(),
                    self.existing_rate_digest.as_option().as_ref(),
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
        if self.existing_rate_id.is_some()
            || self.existing_rate_revision.is_some()
            || self.existing_rate_digest.is_some()
        {
            return Ok(false);
        }
        let Some(append) = self.append_value.as_option().as_ref() else {
            return Ok(false);
        };
        if append.signature_digest != self.source_signature_digest || !append.valid_common()? {
            return Ok(false);
        }
        Ok(match append.fact_kind {
            FxFactKind::Observation => {
                append.revision == 1
                    && append.root_rate_id.is_none()
                    && append.supersedes_rate_id.is_none()
                    && append.correction_reason.is_none()
                    && head_fence_is_absent(
                        &self.expected_head_id,
                        &self.expected_head_revision,
                        &self.expected_head_digest,
                    )
            }
            FxFactKind::Replacement | FxFactKind::Withdrawal => matches!(
                (
                    append.root_rate_id.as_option().as_ref(),
                    append.supersedes_rate_id.as_option().as_ref(),
                    append.correction_reason.as_option().as_ref(),
                    self.expected_head_id.as_option().as_ref(),
                    self.expected_head_revision.as_option().as_ref(),
                    self.expected_head_digest.as_option().as_ref(),
                ),
                (Some(_), Some(supersedes), Some(_), Some(head_id), Some(head_revision), Some(_))
                    if append.revision > 1
                        && supersedes == head_id
                        && head_revision.checked_add(1) == Some(append.revision)
            ),
        })
    }
}

impl EconomicsFxRateAppendV1 {
    fn valid_common(&self) -> Result<bool, ServiceError> {
        let rate_is_valid = match self.fact_kind {
            FxFactKind::Observation | FxFactKind::Replacement => self
                .rate
                .as_option()
                .as_ref()
                .is_some_and(|rate| rate.scale() <= 12 && *rate > Decimal::ZERO),
            FxFactKind::Withdrawal => self.rate.is_none(),
        };
        Ok(self.revision > 0
            && valid_optional_uuid(&self.root_rate_id)
            && valid_optional_uuid(&self.supersedes_rate_id)
            && valid_currency(&self.source_currency)
            && valid_currency(&self.target_currency)
            && self.source_currency != self.target_currency
            && rate_is_valid
            && valid_bounded_text(&self.source_record_hmac_key_version, 100)
            && self.source_priority >= 0
            && parse_datetime(&self.observed_at)? < parse_datetime(&self.valid_until)?)
    }
}

pub(super) fn valid_fx_binding(
    line: &EconomicsCostLineImportV1,
    reporting_currency: &str,
    sources: &[EconomicsFxRateSourceImportV1],
) -> bool {
    if line.source_currency == reporting_currency {
        return line.fx_rate_fact_id.is_none()
            && line.fx_source_ordinal.is_none()
            && line.reporting_source_amount == line.source_amount;
    }
    let Some(ordinal) = line.fx_source_ordinal.as_option().as_ref() else {
        return false;
    };
    let Some(zero_based) = ordinal.checked_sub(1) else {
        return false;
    };
    let Ok(index) = usize::try_from(zero_based) else {
        return false;
    };
    let Some(source) = sources.get(index) else {
        return false;
    };
    match source.resolution {
        EconomicsSourceResolutionV1::Append => line.fx_rate_fact_id.is_none(),
        EconomicsSourceResolutionV1::Existing => matches!(
            (
                line.fx_rate_fact_id.as_option().as_ref(),
                source.existing_rate_id.as_option().as_ref(),
            ),
            (Some(id), Some(existing_id)) if id == existing_id
        ),
    }
}

fn head_fence_is_absent(
    id: &RequiredNullable<Uuid>,
    version: &RequiredNullable<i64>,
    digest: &RequiredNullable<Sha256Digest>,
) -> bool {
    id.is_none() && version.is_none() && digest.is_none()
}

fn valid_optional_uuid(value: &RequiredNullable<Uuid>) -> bool {
    value.as_option().is_none_or(|id| !id.is_nil())
}

fn valid_currency(value: &str) -> bool {
    value.len() == 3 && value.as_bytes().iter().all(u8::is_ascii_uppercase)
}

fn valid_bounded_text(value: &str, max: usize) -> bool {
    value == value.trim() && (1..=max).contains(&value.len())
}

fn parse_datetime(value: &DateTimeText) -> Result<OffsetDateTime, ServiceError> {
    OffsetDateTime::parse(value.as_str(), &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
}
