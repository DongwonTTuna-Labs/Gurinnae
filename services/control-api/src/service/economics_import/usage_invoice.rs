use super::*;

#[path = "usage_invoice/discount.rs"]
mod discount;
#[path = "usage_invoice/invoice.rs"]
mod invoice;
#[path = "usage_invoice/usage.rs"]
mod usage;

pub(super) use discount::*;
pub(super) use invoice::*;
pub(super) use usage::*;

macro_rules! closed_enum {
    ($name:ident { $($variant:ident),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
        #[serde(rename_all = "SCREAMING_SNAKE_CASE")]
        enum $name { $($variant),+ }
    };
}

closed_enum!(CommercialSku {
    EvidenceWorkspaceOrganizationV1
});
closed_enum!(UsageEffect {
    Original,
    Replacement,
    Reversal
});
closed_enum!(MeasurementState {
    Complete,
    Partial,
    Unknown
});
closed_enum!(UsageMeterKind {
    Seat,
    AgentToken,
    ModelRequest,
    SourcePage,
    StorageByteHour,
    DeliveryAttempt,
    ExportByte,
    ApiRequest
});
closed_enum!(UsageReceiptKind {
    IdentityUsageWindow,
    AgentUsageWindow,
    ModelUsageWindow,
    SourceUsageWindow,
    StorageUsageWindow,
    DeliveryUsageWindow,
    ExportUsageWindow,
    ApiUsageWindow
});
closed_enum!(UsageUnit {
    Count,
    Token,
    Request,
    Page,
    ByteHour,
    Attempt,
    Byte
});
closed_enum!(NormalizationBasisKind {
    ActiveContributorCount,
    AgentTokenCount,
    ModelRequestCostUnit,
    SourcePageCount,
    EncryptedByteHour,
    DeliveryAttemptCount,
    ExportByteCount,
    ApiRecordReturnedCount
});
closed_enum!(BillableMetric {
    ActiveContributor,
    ProcessingCredit,
    StorageGbMonth,
    ApiRecordUnit,
    IncludedDelivery,
    IncludedExport
});
closed_enum!(BillableUnit {
    ContributorMonth,
    Credit,
    GbMonth,
    KiloRecords,
    Attempt,
    Byte
});
closed_enum!(InvoiceEffect {
    Original,
    Restatement
});
closed_enum!(InvoiceLineKind {
    WorkspaceBase,
    ActiveContributorBlock,
    ProcessingCreditOverage,
    StorageGbMonthOverage,
    ApiRecordUnitOverage,
    SlaAddOn,
    AccountingAdjustment
});
closed_enum!(TaxCategory {
    Standard,
    ZeroRated,
    Exempt,
    OutOfScope
});
closed_enum!(MembershipEffect {
    Original,
    Restatement
});
closed_enum!(MembershipKind {
    ZeroUsage,
    IncludedAllowance,
    BilledOverage
});

fn any_nil(values: &[Uuid]) -> bool {
    values.iter().any(Uuid::is_nil)
}

fn optional_uuid(value: &RequiredNullable<Uuid>) -> bool {
    value.as_option().is_none_or(|value| !value.is_nil())
}

fn same_presence(values: &[bool]) -> bool {
    values.iter().all(|value| *value) || values.iter().all(|value| !*value)
}

fn no_fence<A, B>(left: &RequiredNullable<A>, right: &RequiredNullable<B>) -> bool {
    left.is_none() && right.is_none()
}

fn full_fence<A, B>(left: &RequiredNullable<A>, right: &RequiredNullable<B>) -> bool {
    left.is_some() && right.is_some()
}

fn valid_head(
    id: &RequiredNullable<Uuid>,
    version: &RequiredNullable<i64>,
    digest: &RequiredNullable<Sha256Digest>,
) -> bool {
    same_presence(&[id.is_some(), version.is_some(), digest.is_some()])
        && optional_uuid(id)
        && version.as_option().is_none_or(|value| value > 0)
}

fn nonnegative(value: &RequiredNullable<Decimal>) -> bool {
    value
        .as_option()
        .is_some_and(|value| value >= Decimal::ZERO)
}

fn valid_trimmed(value: &str, max_len: usize) -> bool {
    !value.is_empty() && value.len() <= max_len && value.trim() == value
}

fn valid_source_system(value: &str) -> bool {
    let mut chars = value.chars();
    chars
        .next()
        .is_some_and(|character| character.is_ascii_lowercase() || character.is_ascii_digit())
        && value.len() <= 128
        && chars.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '.' | '_' | '-')
        })
}

fn valid_currency(value: &str) -> bool {
    value.len() == 3 && value.bytes().all(|value| value.is_ascii_uppercase())
}

fn datetime_not_after(left: &DateTimeText, right: &DateTimeText) -> bool {
    let Ok(left) = OffsetDateTime::parse(left.as_str(), &Rfc3339) else {
        return false;
    };
    let Ok(right) = OffsetDateTime::parse(right.as_str(), &Rfc3339) else {
        return false;
    };
    left <= right
}
