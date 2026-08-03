use std::collections::BTreeSet;

use time::{Date, Duration, OffsetDateTime};
use uuid::Uuid;

use crate::privacy::{PrivacyDigest, PrivacyError, PrivacyRequestType};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum CalendarWeekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl CalendarWeekday {
    const fn index(self) -> usize {
        match self {
            Self::Monday => 0,
            Self::Tuesday => 1,
            Self::Wednesday => 2,
            Self::Thursday => 3,
            Self::Friday => 4,
            Self::Saturday => 5,
            Self::Sunday => 6,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyResponseCalendar {
    pub calendar_version_id: Uuid,
    pub calendar_digest: PrivacyDigest,
    pub timezone: String,
    pub effective_at: OffsetDateTime,
    pub review_expires_at: OffsetDateTime,
    weekend: [bool; 7],
    holidays: BTreeSet<Date>,
}

impl PrivacyResponseCalendar {
    pub fn try_new(
        calendar_version_id: Uuid,
        calendar_digest: PrivacyDigest,
        timezone: impl Into<String>,
        weekend_days: &[CalendarWeekday],
        holidays: BTreeSet<Date>,
        effective_at: OffsetDateTime,
        review_expires_at: OffsetDateTime,
        as_of: OffsetDateTime,
    ) -> Result<Self, PrivacyError> {
        let timezone = timezone.into();
        if calendar_version_id.is_nil()
            || timezone != "Asia/Seoul"
            || weekend_days.is_empty()
            || weekend_days.len() > 6
            || effective_at > as_of
            || review_expires_at <= as_of
            || review_expires_at <= effective_at
        {
            return Err(PrivacyError::CalendarUnavailable);
        }
        let mut weekend = [false; 7];
        for day in weekend_days {
            let index = day.index();
            if weekend[index] {
                return Err(PrivacyError::CalendarUnavailable);
            }
            weekend[index] = true;
        }
        Ok(Self {
            calendar_version_id,
            calendar_digest,
            timezone,
            effective_at,
            review_expires_at,
            weekend,
            holidays,
        })
    }

    pub fn add_business_days(&self, start: Date, days: u16) -> Result<Date, PrivacyError> {
        if days == 0 {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        }
        let mut date = start;
        let mut remaining = days;
        while remaining > 0 {
            date = date
                .checked_add(Duration::days(1))
                .ok_or(PrivacyError::DeadlineOverflow)?;
            if self.is_business_day(date) {
                remaining -= 1;
            }
        }
        Ok(date)
    }

    fn is_business_day(&self, date: Date) -> bool {
        let weekday = match date.weekday() {
            time::Weekday::Monday => CalendarWeekday::Monday,
            time::Weekday::Tuesday => CalendarWeekday::Tuesday,
            time::Weekday::Wednesday => CalendarWeekday::Wednesday,
            time::Weekday::Thursday => CalendarWeekday::Thursday,
            time::Weekday::Friday => CalendarWeekday::Friday,
            time::Weekday::Saturday => CalendarWeekday::Saturday,
            time::Weekday::Sunday => CalendarWeekday::Sunday,
        };
        !self.weekend[weekday.index()] && !self.holidays.contains(&date)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyPolicyVersion(String);

impl PrivacyPolicyVersion {
    pub fn try_new(value: impl Into<String>) -> Result<Self, PrivacyError> {
        let value = value.into();
        let mut bytes = value.bytes();
        let Some(first) = bytes.next() else {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        };
        if value.len() > 100
            || !(first.is_ascii_lowercase() || first.is_ascii_digit())
            || !bytes.all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'.' | b'_' | b'-')
            })
        {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyPolicyAuthority(String);

impl PrivacyPolicyAuthority {
    pub fn try_new(value: impl Into<String>) -> Result<Self, PrivacyError> {
        let value = value.into();
        let mut bytes = value.bytes();
        let Some(first) = bytes.next() else {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        };
        if !(3..=100).contains(&value.len())
            || !first.is_ascii_uppercase()
            || !bytes.all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrivacyPolicyTimezone {
    AsiaSeoul,
}

impl PrivacyPolicyTimezone {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AsiaSeoul => "Asia/Seoul",
        }
    }
}

impl TryFrom<&str> for PrivacyPolicyTimezone {
    type Error = PrivacyError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "Asia/Seoul" => Ok(Self::AsiaSeoul),
            _ => Err(PrivacyError::InvalidDeadlinePolicy),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyResponsePolicyDefinition {
    pub version: PrivacyPolicyVersion,
    pub policy_digest: PrivacyDigest,
    pub authority: PrivacyPolicyAuthority,
    pub timezone: PrivacyPolicyTimezone,
    pub access_business_days: u16,
    pub correction_business_days: u16,
    pub deletion_business_days: u16,
    pub restriction_business_days: u16,
    pub maximum_extension_business_days: u16,
    pub maximum_extension_count: u8,
    pub refusal_notice_business_days: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacyResponsePolicy {
    pub version: PrivacyPolicyVersion,
    pub policy_digest: PrivacyDigest,
    pub authority: PrivacyPolicyAuthority,
    pub timezone: PrivacyPolicyTimezone,
    access_business_days: u16,
    correction_business_days: u16,
    deletion_business_days: u16,
    restriction_business_days: u16,
    maximum_extension_business_days: u16,
    maximum_extension_count: u8,
    refusal_notice_business_days: u16,
}

impl PrivacyResponsePolicy {
    pub fn try_new(definition: PrivacyResponsePolicyDefinition) -> Result<Self, PrivacyError> {
        let due_days_valid = [
            definition.access_business_days,
            definition.correction_business_days,
            definition.deletion_business_days,
            definition.restriction_business_days,
            definition.refusal_notice_business_days,
        ]
        .iter()
        .all(|days| (1..=365).contains(days));
        let extension_policy_valid = matches!(
            (
                definition.maximum_extension_business_days,
                definition.maximum_extension_count,
            ),
            (0, 0) | (1..=365, 1..=10)
        );
        if !due_days_valid || !extension_policy_valid {
            return Err(PrivacyError::InvalidDeadlinePolicy);
        }
        Ok(Self {
            version: definition.version,
            policy_digest: definition.policy_digest,
            authority: definition.authority,
            timezone: definition.timezone,
            access_business_days: definition.access_business_days,
            correction_business_days: definition.correction_business_days,
            deletion_business_days: definition.deletion_business_days,
            restriction_business_days: definition.restriction_business_days,
            maximum_extension_business_days: definition.maximum_extension_business_days,
            maximum_extension_count: definition.maximum_extension_count,
            refusal_notice_business_days: definition.refusal_notice_business_days,
        })
    }

    pub fn request_due_date(
        &self,
        calendar: &PrivacyResponseCalendar,
        request_type: PrivacyRequestType,
        identity_verified_date: Date,
    ) -> Result<Date, PrivacyError> {
        self.ensure_calendar_binding(calendar)?;
        let days = match request_type {
            PrivacyRequestType::Access => self.access_business_days,
            PrivacyRequestType::Correction => self.correction_business_days,
            PrivacyRequestType::Deletion => self.deletion_business_days,
            PrivacyRequestType::Restriction => self.restriction_business_days,
        };
        calendar.add_business_days(identity_verified_date, days)
    }

    pub fn extension_due_date(
        &self,
        calendar: &PrivacyResponseCalendar,
        current_due_date: Date,
        requested_extension_business_days: u16,
        extension_count: u8,
        requested_at: OffsetDateTime,
        current_due_at: OffsetDateTime,
    ) -> Result<Date, PrivacyError> {
        self.ensure_calendar_binding(calendar)?;
        if requested_extension_business_days == 0
            || requested_extension_business_days > self.maximum_extension_business_days
            || extension_count >= self.maximum_extension_count
            || requested_at >= current_due_at
        {
            return Err(PrivacyError::ExtensionNotAllowed);
        }
        calendar.add_business_days(current_due_date, requested_extension_business_days)
    }

    pub fn refusal_notice_due_date(
        &self,
        calendar: &PrivacyResponseCalendar,
        decided_date: Date,
    ) -> Result<Date, PrivacyError> {
        self.ensure_calendar_binding(calendar)?;
        calendar.add_business_days(decided_date, self.refusal_notice_business_days)
    }

    fn ensure_calendar_binding(
        &self,
        calendar: &PrivacyResponseCalendar,
    ) -> Result<(), PrivacyError> {
        if calendar.timezone == self.timezone.as_str() {
            Ok(())
        } else {
            Err(PrivacyError::CalendarUnavailable)
        }
    }
}
