use super::*;
use serde::de::Error as _;

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "operationId", deny_unknown_fields)]
pub(super) enum EconomicsImportOperationV1 {
    #[serde(rename = "recordCommercialQualification")]
    RecordCommercialQualification(EconomicsQualificationImportV1),
    #[serde(rename = "importCostAllocationClose")]
    ImportCostAllocationClose(EconomicsCostCloseImportV1),
    #[serde(rename = "createTariffVersion")]
    CreateTariffVersion(EconomicsTariffImportV1),
    #[serde(rename = "recordCommercialContractPeriod")]
    RecordCommercialContractPeriod(EconomicsContractImportV1),
    #[serde(rename = "recordUsageWindow")]
    RecordUsageWindow(EconomicsUsageWindowImportV1),
    #[serde(rename = "recordInvoice")]
    RecordInvoice(EconomicsInvoiceImportV1),
    #[serde(rename = "recordRevenue")]
    RecordRevenue(EconomicsRevenueImportV1),
    #[serde(rename = "recordAccountingCorrection")]
    RecordAccountingCorrection(EconomicsAccountingCorrectionsImportV1),
    #[serde(rename = "recordCashApplication")]
    RecordCashApplication(EconomicsCashApplicationsImportV1),
    #[serde(rename = "recordTaxInvoiceIssuance")]
    RecordTaxInvoiceIssuance(EconomicsTaxInvoicesImportV1),
    #[serde(rename = "recordCollectionFailure")]
    RecordCollectionFailure(EconomicsCollectionFailureImportV1),
}

#[derive(Deserialize)]
#[serde(tag = "operationId", deny_unknown_fields)]
enum EconomicsImportOperationWireV1 {
    #[serde(rename = "recordCommercialQualification")]
    RecordCommercialQualification(EconomicsQualificationImportV1),
    #[serde(rename = "importCostAllocationClose")]
    ImportCostAllocationClose(EconomicsCostCloseImportV1),
    #[serde(rename = "createTariffVersion")]
    CreateTariffVersion(EconomicsTariffImportV1),
    #[serde(rename = "recordCommercialContractPeriod")]
    RecordCommercialContractPeriod(EconomicsContractImportV1),
    #[serde(rename = "recordUsageWindow")]
    RecordUsageWindow(EconomicsUsageWindowImportV1),
    #[serde(rename = "recordInvoice")]
    RecordInvoice(EconomicsInvoiceImportV1),
    #[serde(rename = "recordRevenue")]
    RecordRevenue(EconomicsRevenueImportV1),
    #[serde(rename = "recordAccountingCorrection")]
    RecordAccountingCorrection(EconomicsAccountingCorrectionsImportV1),
    #[serde(rename = "recordCashApplication")]
    RecordCashApplication(EconomicsCashApplicationsImportV1),
    #[serde(rename = "recordTaxInvoiceIssuance")]
    RecordTaxInvoiceIssuance(EconomicsTaxInvoicesImportV1),
    #[serde(rename = "recordCollectionFailure")]
    RecordCollectionFailure(EconomicsCollectionFailureImportV1),
}

impl From<EconomicsImportOperationWireV1> for EconomicsImportOperationV1 {
    fn from(value: EconomicsImportOperationWireV1) -> Self {
        match value {
            EconomicsImportOperationWireV1::RecordCommercialQualification(value) => {
                Self::RecordCommercialQualification(value)
            }
            EconomicsImportOperationWireV1::ImportCostAllocationClose(value) => {
                Self::ImportCostAllocationClose(value)
            }
            EconomicsImportOperationWireV1::CreateTariffVersion(value) => {
                Self::CreateTariffVersion(value)
            }
            EconomicsImportOperationWireV1::RecordCommercialContractPeriod(value) => {
                Self::RecordCommercialContractPeriod(value)
            }
            EconomicsImportOperationWireV1::RecordUsageWindow(value) => {
                Self::RecordUsageWindow(value)
            }
            EconomicsImportOperationWireV1::RecordInvoice(value) => Self::RecordInvoice(value),
            EconomicsImportOperationWireV1::RecordRevenue(value) => Self::RecordRevenue(value),
            EconomicsImportOperationWireV1::RecordAccountingCorrection(value) => {
                Self::RecordAccountingCorrection(value)
            }
            EconomicsImportOperationWireV1::RecordCashApplication(value) => {
                Self::RecordCashApplication(value)
            }
            EconomicsImportOperationWireV1::RecordTaxInvoiceIssuance(value) => {
                Self::RecordTaxInvoiceIssuance(value)
            }
            EconomicsImportOperationWireV1::RecordCollectionFailure(value) => {
                Self::RecordCollectionFailure(value)
            }
        }
    }
}

impl<'de> Deserialize<'de> for EconomicsImportOperationV1 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        validate_canonical_decimal_wire(&value).map_err(D::Error::custom)?;
        serde_json::from_value::<EconomicsImportOperationWireV1>(value)
            .map(Into::into)
            .map_err(D::Error::custom)
    }
}

impl EconomicsImportOperationV1 {
    pub(super) const fn as_str(&self) -> &'static str {
        match self {
            Self::RecordCommercialQualification(_) => "recordCommercialQualification",
            Self::ImportCostAllocationClose(_) => "importCostAllocationClose",
            Self::CreateTariffVersion(_) => "createTariffVersion",
            Self::RecordCommercialContractPeriod(_) => "recordCommercialContractPeriod",
            Self::RecordUsageWindow(_) => "recordUsageWindow",
            Self::RecordInvoice(_) => "recordInvoice",
            Self::RecordRevenue(_) => "recordRevenue",
            Self::RecordAccountingCorrection(_) => "recordAccountingCorrection",
            Self::RecordCashApplication(_) => "recordCashApplication",
            Self::RecordTaxInvoiceIssuance(_) => "recordTaxInvoiceIssuance",
            Self::RecordCollectionFailure(_) => "recordCollectionFailure",
        }
    }

    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        match self {
            Self::RecordCommercialQualification(value) => value.validate(),
            Self::ImportCostAllocationClose(value) => value.validate(),
            Self::CreateTariffVersion(value) => value.validate(),
            Self::RecordCommercialContractPeriod(value) => value.validate(),
            Self::RecordUsageWindow(value) => value.validate(),
            Self::RecordInvoice(value) => value.validate(),
            Self::RecordRevenue(value) => value.validate(),
            Self::RecordAccountingCorrection(value) => value.validate(),
            Self::RecordCashApplication(value) => value.validate(),
            Self::RecordTaxInvoiceIssuance(value) => value.validate(),
            Self::RecordCollectionFailure(value) => value.validate(),
        }
    }

    pub(super) const fn allows_disposition(&self, disposition: EconomicsImportDisposition) -> bool {
        match self {
            Self::RecordCommercialQualification(_) => matches!(
                disposition,
                EconomicsImportDisposition::Recorded
                    | EconomicsImportDisposition::Replaced
                    | EconomicsImportDisposition::Reversed
            ),
            Self::ImportCostAllocationClose(_)
            | Self::RecordCommercialContractPeriod(_)
            | Self::RecordInvoice(_) => matches!(
                disposition,
                EconomicsImportDisposition::Recorded | EconomicsImportDisposition::Replaced
            ),
            Self::CreateTariffVersion(_) | Self::RecordRevenue(_) => {
                matches!(disposition, EconomicsImportDisposition::Recorded)
            }
            Self::RecordUsageWindow(_)
            | Self::RecordCashApplication(_)
            | Self::RecordTaxInvoiceIssuance(_) => matches!(
                disposition,
                EconomicsImportDisposition::Recorded
                    | EconomicsImportDisposition::Replaced
                    | EconomicsImportDisposition::Reversed
            ),
            Self::RecordAccountingCorrection(_) => matches!(
                disposition,
                EconomicsImportDisposition::Recorded | EconomicsImportDisposition::Reversed
            ),
            Self::RecordCollectionFailure(_) => {
                matches!(disposition, EconomicsImportDisposition::ReviewTaskCreated)
            }
        }
    }
}
