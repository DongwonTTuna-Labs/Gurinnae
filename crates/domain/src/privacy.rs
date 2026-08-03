use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::{Date, OffsetDateTime};
use uuid::Uuid;

pub use crate::privacy_policy::{
    CalendarWeekday, PrivacyPolicyAuthority, PrivacyPolicyTimezone, PrivacyPolicyVersion,
    PrivacyResponseCalendar, PrivacyResponsePolicy, PrivacyResponsePolicyDefinition,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PrivacyRequestType {
    Access,
    Correction,
    Deletion,
    Restriction,
}

impl PrivacyRequestType {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Access => "ACCESS",
            Self::Correction => "CORRECTION",
            Self::Deletion => "DELETION",
            Self::Restriction => "RESTRICTION",
        }
    }
}

impl TryFrom<&str> for PrivacyRequestType {
    type Error = PrivacyError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "ACCESS" => Ok(Self::Access),
            "CORRECTION" => Ok(Self::Correction),
            "DELETION" => Ok(Self::Deletion),
            "RESTRICTION" => Ok(Self::Restriction),
            _ => Err(PrivacyError::InvalidRequestType),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PrivacyRequestState {
    Received,
    Review,
    Approved,
    Rejected,
    Completed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PrivacyIdentityState {
    PendingVerification,
    Verified,
}

impl PrivacyIdentityState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PendingVerification => "PENDING_VERIFICATION",
            Self::Verified => "VERIFIED",
        }
    }
}

impl TryFrom<&str> for PrivacyIdentityState {
    type Error = PrivacyError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "PENDING_VERIFICATION" => Ok(Self::PendingVerification),
            "VERIFIED" => Ok(Self::Verified),
            _ => Err(PrivacyError::InvalidIdentityState),
        }
    }
}

impl PrivacyRequestState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Received => "RECEIVED",
            Self::Review => "REVIEW",
            Self::Approved => "APPROVED",
            Self::Rejected => "REJECTED",
            Self::Completed => "COMPLETED",
        }
    }

    pub const fn may_transition_to(self, target: Self) -> bool {
        matches!(
            (self, target),
            (Self::Received, Self::Review)
                | (Self::Review, Self::Approved | Self::Rejected)
                | (Self::Approved, Self::Completed)
        )
    }
}

impl TryFrom<&str> for PrivacyRequestState {
    type Error = PrivacyError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "RECEIVED" => Ok(Self::Received),
            "REVIEW" => Ok(Self::Review),
            "APPROVED" => Ok(Self::Approved),
            "REJECTED" => Ok(Self::Rejected),
            "COMPLETED" => Ok(Self::Completed),
            _ => Err(PrivacyError::InvalidState),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PrivacyScopeKind {
    AllVerifiedSubjectData,
    ObjectSet,
    DateRange,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PrivacyObjectType {
    Response,
    Correction,
    Subscription,
    CommunicationEndpoint,
    Publication,
    Evidence,
    AuditSubjectRecord,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PrivacyObjectRef {
    pub object_type: PrivacyObjectType,
    pub object_id: Uuid,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PrivacyRequestScope {
    pub scope_kind: PrivacyScopeKind,
    pub object_refs: Vec<PrivacyObjectRef>,
    #[serde(with = "optional_iso_date")]
    pub date_from: Option<Date>,
    #[serde(with = "optional_iso_date")]
    pub date_to: Option<Date>,
    pub include_derivatives: bool,
    pub include_backups: bool,
}

mod optional_iso_date {
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};
    use time::Date;

    const ISO_DATE_FORMAT: &str = "[year]-[month]-[day]";

    pub fn serialize<S>(value: &Option<Date>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match value {
            Some(date) => {
                let format = time::format_description::parse(ISO_DATE_FORMAT)
                    .map_err(serde::ser::Error::custom)?;
                let rendered = date.format(&format).map_err(serde::ser::Error::custom)?;
                if !has_iso_date_shape(&rendered) {
                    return Err(serde::ser::Error::custom(
                        "privacy scope date is outside YYYY-MM-DD",
                    ));
                }
                serializer.serialize_some(&rendered)
            }
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Date>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let Some(value) = Option::<String>::deserialize(deserializer)? else {
            return Ok(None);
        };
        if !has_iso_date_shape(&value) {
            return Err(D::Error::custom("privacy scope date must use YYYY-MM-DD"));
        }
        let format = time::format_description::parse(ISO_DATE_FORMAT).map_err(D::Error::custom)?;
        Date::parse(&value, &format)
            .map(Some)
            .map_err(D::Error::custom)
    }

    fn has_iso_date_shape(value: &str) -> bool {
        let bytes = value.as_bytes();
        bytes.len() == 10
            && bytes[4] == b'-'
            && bytes[7] == b'-'
            && bytes[..4].iter().all(u8::is_ascii_digit)
            && bytes[5..7].iter().all(u8::is_ascii_digit)
            && bytes[8..].iter().all(u8::is_ascii_digit)
    }
}

impl PrivacyRequestScope {
    pub fn validate(self) -> Result<Self, PrivacyError> {
        if self.object_refs.len() > 1_000
            || self.object_refs.iter().any(|item| item.object_id.is_nil())
            || self.object_refs.iter().collect::<BTreeSet<_>>().len() != self.object_refs.len()
        {
            return Err(PrivacyError::InvalidScope);
        }
        let valid_shape = match self.scope_kind {
            PrivacyScopeKind::AllVerifiedSubjectData => {
                self.object_refs.is_empty() && self.date_from.is_none() && self.date_to.is_none()
            }
            PrivacyScopeKind::ObjectSet => {
                !self.object_refs.is_empty() && self.date_from.is_none() && self.date_to.is_none()
            }
            PrivacyScopeKind::DateRange => {
                self.object_refs.is_empty()
                    && self
                        .date_from
                        .zip(self.date_to)
                        .is_some_and(|(from, to)| from <= to)
            }
        };
        if !valid_shape {
            return Err(PrivacyError::InvalidScope);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct PrivacyDigest(String);

impl PrivacyDigest {
    pub fn try_new(value: impl Into<String>) -> Result<Self, PrivacyError> {
        let value = value.into();
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(PrivacyError::InvalidDigest);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyRequestSummary {
    pub privacy_request_id: Uuid,
    pub request_type: PrivacyRequestType,
    pub state: PrivacyRequestState,
    pub jurisdiction: String,
    pub scope_digest: PrivacyDigest,
    pub identity_state: PrivacyIdentityState,
    pub identity_verified_at: Option<OffsetDateTime>,
    pub due_at: Option<OffsetDateTime>,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

impl PrivacyRequestSummary {
    #[expect(
        clippy::too_many_arguments,
        reason = "the public privacy receipt validates one closed persisted projection"
    )]
    pub fn try_new(
        privacy_request_id: Uuid,
        request_type: PrivacyRequestType,
        state: PrivacyRequestState,
        jurisdiction: impl Into<String>,
        scope_digest: PrivacyDigest,
        identity_state: PrivacyIdentityState,
        identity_verified_at: Option<OffsetDateTime>,
        due_at: Option<OffsetDateTime>,
        created_at: OffsetDateTime,
        updated_at: OffsetDateTime,
    ) -> Result<Self, PrivacyError> {
        let jurisdiction = jurisdiction.into();
        let identity_clock_valid = match (identity_state, identity_verified_at, due_at) {
            (PrivacyIdentityState::PendingVerification, None, None) => true,
            (PrivacyIdentityState::Verified, Some(verified_at), Some(due_at)) => {
                created_at <= verified_at && due_at > verified_at
            }
            _ => false,
        };
        if privacy_request_id.is_nil()
            || !(2..=64).contains(&jurisdiction.chars().count())
            || jurisdiction.trim() != jurisdiction
            || updated_at < created_at
            || !identity_clock_valid
        {
            return Err(PrivacyError::InvalidProjection);
        }
        Ok(Self {
            privacy_request_id,
            request_type,
            state,
            jurisdiction,
            scope_digest,
            identity_state,
            identity_verified_at,
            due_at,
            created_at,
            updated_at,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PrivacyError {
    #[error("privacy request type is outside the closed catalog")]
    InvalidRequestType,
    #[error("privacy request state is outside the closed lifecycle")]
    InvalidState,
    #[error("privacy identity verification state is outside the closed lifecycle")]
    InvalidIdentityState,
    #[error("privacy request scope is invalid")]
    InvalidScope,
    #[error("privacy digest is invalid")]
    InvalidDigest,
    #[error("an active approved privacy response calendar is unavailable")]
    CalendarUnavailable,
    #[error("privacy response deadline policy is invalid")]
    InvalidDeadlinePolicy,
    #[error("privacy response deadline overflows the supported date range")]
    DeadlineOverflow,
    #[error("privacy response extension is expired or already used")]
    ExtensionNotAllowed,
    #[error("privacy request projection violates its persisted authority")]
    InvalidProjection,
}
