//! Generated from specs/domain/state-machines.yaml.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum InvestigationState {
    #[serde(rename = "SIGNAL_DETECTED")]
    SignalDetected,
    #[serde(rename = "TRIAGE")]
    Triage,
    #[serde(rename = "INVESTIGATING")]
    Investigating,
    #[serde(rename = "AWAITING_RESPONSE")]
    AwaitingResponse,
    #[serde(rename = "EDITORIAL_REVIEW")]
    EditorialReview,
    #[serde(rename = "LEGAL_REVIEW")]
    LegalReview,
    #[serde(rename = "READY_TO_PUBLISH")]
    ReadyToPublish,
    #[serde(rename = "CLOSED")]
    Closed,
}

impl InvestigationState {
    pub const ALL: &'static [Self] = &[
        Self::SignalDetected,
        Self::Triage,
        Self::Investigating,
        Self::AwaitingResponse,
        Self::EditorialReview,
        Self::LegalReview,
        Self::ReadyToPublish,
        Self::Closed,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SignalDetected => "SIGNAL_DETECTED",
            Self::Triage => "TRIAGE",
            Self::Investigating => "INVESTIGATING",
            Self::AwaitingResponse => "AWAITING_RESPONSE",
            Self::EditorialReview => "EDITORIAL_REVIEW",
            Self::LegalReview => "LEGAL_REVIEW",
            Self::ReadyToPublish => "READY_TO_PUBLISH",
            Self::Closed => "CLOSED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum PublicationState {
    #[serde(rename = "NEVER_PUBLISHED")]
    NeverPublished,
    #[serde(rename = "PUBLISHED_ANOMALY")]
    PublishedAnomaly,
    #[serde(rename = "PUBLISHED_EXPLAINED")]
    PublishedExplained,
    #[serde(rename = "OFFICIALLY_CONFIRMED")]
    OfficiallyConfirmed,
    #[serde(rename = "CORRECTED")]
    Corrected,
    #[serde(rename = "RETRACTED")]
    Retracted,
    #[serde(rename = "TEMPORARILY_RESTRICTED")]
    TemporarilyRestricted,
}

impl PublicationState {
    pub const ALL: &'static [Self] = &[
        Self::NeverPublished,
        Self::PublishedAnomaly,
        Self::PublishedExplained,
        Self::OfficiallyConfirmed,
        Self::Corrected,
        Self::Retracted,
        Self::TemporarilyRestricted,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NeverPublished => "NEVER_PUBLISHED",
            Self::PublishedAnomaly => "PUBLISHED_ANOMALY",
            Self::PublishedExplained => "PUBLISHED_EXPLAINED",
            Self::OfficiallyConfirmed => "OFFICIALLY_CONFIRMED",
            Self::Corrected => "CORRECTED",
            Self::Retracted => "RETRACTED",
            Self::TemporarilyRestricted => "TEMPORARILY_RESTRICTED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ResolutionCode {
    #[serde(rename = "NONE")]
    None,
    #[serde(rename = "DATA_ERROR")]
    DataError,
    #[serde(rename = "DUPLICATE")]
    Duplicate,
    #[serde(rename = "EXPLAINED")]
    Explained,
    #[serde(rename = "INSUFFICIENT_EVIDENCE")]
    InsufficientEvidence,
    #[serde(rename = "REFERRED_CONFIDENTIAL")]
    ReferredConfidential,
    #[serde(rename = "ARCHIVED")]
    Archived,
}

impl ResolutionCode {
    pub const ALL: &'static [Self] = &[
        Self::None,
        Self::DataError,
        Self::Duplicate,
        Self::Explained,
        Self::InsufficientEvidence,
        Self::ReferredConfidential,
        Self::Archived,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "NONE",
            Self::DataError => "DATA_ERROR",
            Self::Duplicate => "DUPLICATE",
            Self::Explained => "EXPLAINED",
            Self::InsufficientEvidence => "INSUFFICIENT_EVIDENCE",
            Self::ReferredConfidential => "REFERRED_CONFIDENTIAL",
            Self::Archived => "ARCHIVED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum SignalStatus {
    #[serde(rename = "NEW")]
    New,
    #[serde(rename = "ASSIGNED")]
    Assigned,
    #[serde(rename = "NEEDS_DATA")]
    NeedsData,
    #[serde(rename = "LINKED")]
    Linked,
    #[serde(rename = "DISMISSED")]
    Dismissed,
    #[serde(rename = "DUPLICATE")]
    Duplicate,
}

impl SignalStatus {
    pub const ALL: &'static [Self] = &[
        Self::New,
        Self::Assigned,
        Self::NeedsData,
        Self::Linked,
        Self::Dismissed,
        Self::Duplicate,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::New => "NEW",
            Self::Assigned => "ASSIGNED",
            Self::NeedsData => "NEEDS_DATA",
            Self::Linked => "LINKED",
            Self::Dismissed => "DISMISSED",
            Self::Duplicate => "DUPLICATE",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum EvidenceVerificationStatus {
    #[serde(rename = "PENDING")]
    Pending,
    #[serde(rename = "VERIFIED")]
    Verified,
    #[serde(rename = "REJECTED")]
    Rejected,
    #[serde(rename = "NEEDS_WORK")]
    NeedsWork,
}

impl EvidenceVerificationStatus {
    pub const ALL: &'static [Self] = &[
        Self::Pending,
        Self::Verified,
        Self::Rejected,
        Self::NeedsWork,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Verified => "VERIFIED",
            Self::Rejected => "REJECTED",
            Self::NeedsWork => "NEEDS_WORK",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ClaimValidationStatus {
    #[serde(rename = "DRAFT")]
    Draft,
    #[serde(rename = "VALID")]
    Valid,
    #[serde(rename = "BLOCKED")]
    Blocked,
    #[serde(rename = "SUPERSEDED")]
    Superseded,
}

impl ClaimValidationStatus {
    pub const ALL: &'static [Self] = &[Self::Draft, Self::Valid, Self::Blocked, Self::Superseded];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Draft => "DRAFT",
            Self::Valid => "VALID",
            Self::Blocked => "BLOCKED",
            Self::Superseded => "SUPERSEDED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ResponseRequestStatus {
    #[serde(rename = "DRAFT")]
    Draft,
    #[serde(rename = "SENT")]
    Sent,
    #[serde(rename = "VIEWED")]
    Viewed,
    #[serde(rename = "SUBMITTED")]
    Submitted,
    #[serde(rename = "CLOSED")]
    Closed,
    #[serde(rename = "EXPIRED")]
    Expired,
}

impl ResponseRequestStatus {
    pub const ALL: &'static [Self] = &[
        Self::Draft,
        Self::Sent,
        Self::Viewed,
        Self::Submitted,
        Self::Closed,
        Self::Expired,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Draft => "DRAFT",
            Self::Sent => "SENT",
            Self::Viewed => "VIEWED",
            Self::Submitted => "SUBMITTED",
            Self::Closed => "CLOSED",
            Self::Expired => "EXPIRED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ResponseEditorialStatus {
    #[serde(rename = "PENDING")]
    Pending,
    #[serde(rename = "ACCEPTED")]
    Accepted,
    #[serde(rename = "PARTIAL")]
    Partial,
    #[serde(rename = "REJECTED")]
    Rejected,
    #[serde(rename = "PUBLISHED")]
    Published,
}

impl ResponseEditorialStatus {
    pub const ALL: &'static [Self] = &[
        Self::Pending,
        Self::Accepted,
        Self::Partial,
        Self::Rejected,
        Self::Published,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Accepted => "ACCEPTED",
            Self::Partial => "PARTIAL",
            Self::Rejected => "REJECTED",
            Self::Published => "PUBLISHED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ReviewStatus {
    #[serde(rename = "UNASSIGNED")]
    Unassigned,
    #[serde(rename = "ASSIGNED")]
    Assigned,
    #[serde(rename = "IN_PROGRESS")]
    InProgress,
    #[serde(rename = "COMPLETED")]
    Completed,
    #[serde(rename = "CANCELLED")]
    Cancelled,
}

impl ReviewStatus {
    pub const ALL: &'static [Self] = &[
        Self::Unassigned,
        Self::Assigned,
        Self::InProgress,
        Self::Completed,
        Self::Cancelled,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unassigned => "UNASSIGNED",
            Self::Assigned => "ASSIGNED",
            Self::InProgress => "IN_PROGRESS",
            Self::Completed => "COMPLETED",
            Self::Cancelled => "CANCELLED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ReviewDecision {
    #[serde(rename = "APPROVE")]
    Approve,
    #[serde(rename = "REJECT")]
    Reject,
    #[serde(rename = "CHANGES_REQUIRED")]
    ChangesRequired,
}

impl ReviewDecision {
    pub const ALL: &'static [Self] = &[Self::Approve, Self::Reject, Self::ChangesRequired];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Approve => "APPROVE",
            Self::Reject => "REJECT",
            Self::ChangesRequired => "CHANGES_REQUIRED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum HypothesisStatus {
    #[serde(rename = "OPEN")]
    Open,
    #[serde(rename = "SUPPORTED")]
    Supported,
    #[serde(rename = "CONTRADICTED")]
    Contradicted,
    #[serde(rename = "RESOLVED")]
    Resolved,
}

impl HypothesisStatus {
    pub const ALL: &'static [Self] = &[
        Self::Open,
        Self::Supported,
        Self::Contradicted,
        Self::Resolved,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Open => "OPEN",
            Self::Supported => "SUPPORTED",
            Self::Contradicted => "CONTRADICTED",
            Self::Resolved => "RESOLVED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum JobStatus {
    #[serde(rename = "QUEUED")]
    Queued,
    #[serde(rename = "LEASED")]
    Leased,
    #[serde(rename = "RUNNING")]
    Running,
    #[serde(rename = "SUCCEEDED")]
    Succeeded,
    #[serde(rename = "FAILED")]
    Failed,
    #[serde(rename = "DEAD_LETTER")]
    DeadLetter,
    #[serde(rename = "CANCELLED")]
    Cancelled,
    #[serde(rename = "QUARANTINED")]
    Quarantined,
}

impl JobStatus {
    pub const ALL: &'static [Self] = &[
        Self::Queued,
        Self::Leased,
        Self::Running,
        Self::Succeeded,
        Self::Failed,
        Self::DeadLetter,
        Self::Cancelled,
        Self::Quarantined,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "QUEUED",
            Self::Leased => "LEASED",
            Self::Running => "RUNNING",
            Self::Succeeded => "SUCCEEDED",
            Self::Failed => "FAILED",
            Self::DeadLetter => "DEAD_LETTER",
            Self::Cancelled => "CANCELLED",
            Self::Quarantined => "QUARANTINED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum SourceRunStatus {
    #[serde(rename = "QUEUED")]
    Queued,
    #[serde(rename = "RUNNING")]
    Running,
    #[serde(rename = "SUCCEEDED")]
    Succeeded,
    #[serde(rename = "FAILED")]
    Failed,
    #[serde(rename = "PAUSED")]
    Paused,
    #[serde(rename = "CANCELLED")]
    Cancelled,
}

impl SourceRunStatus {
    pub const ALL: &'static [Self] = &[
        Self::Queued,
        Self::Running,
        Self::Succeeded,
        Self::Failed,
        Self::Paused,
        Self::Cancelled,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "QUEUED",
            Self::Running => "RUNNING",
            Self::Succeeded => "SUCCEEDED",
            Self::Failed => "FAILED",
            Self::Paused => "PAUSED",
            Self::Cancelled => "CANCELLED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum AgentRunStatus {
    #[serde(rename = "QUEUED")]
    Queued,
    #[serde(rename = "RUNNING")]
    Running,
    #[serde(rename = "SUCCEEDED")]
    Succeeded,
    #[serde(rename = "FAILED")]
    Failed,
    #[serde(rename = "CANCELLED")]
    Cancelled,
    #[serde(rename = "BUDGET_BLOCKED")]
    BudgetBlocked,
    #[serde(rename = "POLICY_BLOCKED")]
    PolicyBlocked,
}

impl AgentRunStatus {
    pub const ALL: &'static [Self] = &[
        Self::Queued,
        Self::Running,
        Self::Succeeded,
        Self::Failed,
        Self::Cancelled,
        Self::BudgetBlocked,
        Self::PolicyBlocked,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "QUEUED",
            Self::Running => "RUNNING",
            Self::Succeeded => "SUCCEEDED",
            Self::Failed => "FAILED",
            Self::Cancelled => "CANCELLED",
            Self::BudgetBlocked => "BUDGET_BLOCKED",
            Self::PolicyBlocked => "POLICY_BLOCKED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ClaimType {
    #[serde(rename = "FACT")]
    Fact,
    #[serde(rename = "CALCULATION")]
    Calculation,
    #[serde(rename = "INFERENCE")]
    Inference,
    #[serde(rename = "LIMITATION")]
    Limitation,
    #[serde(rename = "OFFICIAL_OUTCOME")]
    OfficialOutcome,
}

impl ClaimType {
    pub const ALL: &'static [Self] = &[
        Self::Fact,
        Self::Calculation,
        Self::Inference,
        Self::Limitation,
        Self::OfficialOutcome,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Fact => "FACT",
            Self::Calculation => "CALCULATION",
            Self::Inference => "INFERENCE",
            Self::Limitation => "LIMITATION",
            Self::OfficialOutcome => "OFFICIAL_OUTCOME",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ResponseSummaryStatus {
    #[serde(rename = "NOT_REQUIRED")]
    NotRequired,
    #[serde(rename = "NOT_SENT")]
    NotSent,
    #[serde(rename = "SENT")]
    Sent,
    #[serde(rename = "DELIVERED")]
    Delivered,
    #[serde(rename = "RECEIVED")]
    Received,
    #[serde(rename = "INCORPORATED")]
    Incorporated,
    #[serde(rename = "CLOSED_NO_RESPONSE")]
    ClosedNoResponse,
}

impl ResponseSummaryStatus {
    pub const ALL: &'static [Self] = &[
        Self::NotRequired,
        Self::NotSent,
        Self::Sent,
        Self::Delivered,
        Self::Received,
        Self::Incorporated,
        Self::ClosedNoResponse,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotRequired => "NOT_REQUIRED",
            Self::NotSent => "NOT_SENT",
            Self::Sent => "SENT",
            Self::Delivered => "DELIVERED",
            Self::Received => "RECEIVED",
            Self::Incorporated => "INCORPORATED",
            Self::ClosedNoResponse => "CLOSED_NO_RESPONSE",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ContractStatus {
    #[serde(rename = "ANNOUNCED")]
    Announced,
    #[serde(rename = "AWARDED")]
    Awarded,
    #[serde(rename = "ACTIVE")]
    Active,
    #[serde(rename = "COMPLETED")]
    Completed,
    #[serde(rename = "CANCELLED")]
    Cancelled,
    #[serde(rename = "SUPERSEDED")]
    Superseded,
    #[serde(rename = "UNKNOWN")]
    Unknown,
}

impl ContractStatus {
    pub const ALL: &'static [Self] = &[
        Self::Announced,
        Self::Awarded,
        Self::Active,
        Self::Completed,
        Self::Cancelled,
        Self::Superseded,
        Self::Unknown,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Announced => "ANNOUNCED",
            Self::Awarded => "AWARDED",
            Self::Active => "ACTIVE",
            Self::Completed => "COMPLETED",
            Self::Cancelled => "CANCELLED",
            Self::Superseded => "SUPERSEDED",
            Self::Unknown => "UNKNOWN",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum SourceDocumentProcessingStatus {
    #[serde(rename = "DISCOVERED")]
    Discovered,
    #[serde(rename = "FETCHED")]
    Fetched,
    #[serde(rename = "PARSED")]
    Parsed,
    #[serde(rename = "QUARANTINED")]
    Quarantined,
    #[serde(rename = "REJECTED")]
    Rejected,
}

impl SourceDocumentProcessingStatus {
    pub const ALL: &'static [Self] = &[
        Self::Discovered,
        Self::Fetched,
        Self::Parsed,
        Self::Quarantined,
        Self::Rejected,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Discovered => "DISCOVERED",
            Self::Fetched => "FETCHED",
            Self::Parsed => "PARSED",
            Self::Quarantined => "QUARANTINED",
            Self::Rejected => "REJECTED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum SourceRecordStatus {
    #[serde(rename = "CURRENT")]
    Current,
    #[serde(rename = "SUPERSEDED")]
    Superseded,
    #[serde(rename = "DELETED_UPSTREAM")]
    DeletedUpstream,
}

impl SourceRecordStatus {
    pub const ALL: &'static [Self] = &[Self::Current, Self::Superseded, Self::DeletedUpstream];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Current => "CURRENT",
            Self::Superseded => "SUPERSEDED",
            Self::DeletedUpstream => "DELETED_UPSTREAM",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum AttachmentScanStatus {
    #[serde(rename = "PENDING")]
    Pending,
    #[serde(rename = "CLEAN")]
    Clean,
    #[serde(rename = "INFECTED")]
    Infected,
    #[serde(rename = "FAILED")]
    Failed,
}

impl AttachmentScanStatus {
    pub const ALL: &'static [Self] = &[Self::Pending, Self::Clean, Self::Infected, Self::Failed];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Clean => "CLEAN",
            Self::Infected => "INFECTED",
            Self::Failed => "FAILED",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum SubscriptionStatus {
    #[serde(rename = "PENDING")]
    Pending,
    #[serde(rename = "ACTIVE")]
    Active,
    #[serde(rename = "PAUSED")]
    Paused,
    #[serde(rename = "UNSUBSCRIBED")]
    Unsubscribed,
}

impl SubscriptionStatus {
    pub const ALL: &'static [Self] = &[
        Self::Pending,
        Self::Active,
        Self::Paused,
        Self::Unsubscribed,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Active => "ACTIVE",
            Self::Paused => "PAUSED",
            Self::Unsubscribed => "UNSUBSCRIBED",
        }
    }
}
