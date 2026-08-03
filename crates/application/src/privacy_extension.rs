use crate::privacy::PrivacyCommandError;

/// The complete caller-supplied payload for a privacy-request EXTEND transition.
/// Policy, calendar, extension-count, timing, and due-date inputs stay owner-derived.
#[derive(Clone, Eq, PartialEq)]
pub struct PrivacyExtensionInput {
    extension_reason_code: String,
    extension_reason: String,
    extension_business_days: i32,
}

impl PrivacyExtensionInput {
    pub fn try_new(
        extension_reason_code: impl Into<String>,
        extension_reason: impl Into<String>,
        extension_business_days: i32,
    ) -> Result<Self, PrivacyCommandError> {
        let extension_reason_code = extension_reason_code.into();
        let extension_reason = extension_reason.into();
        if !valid_caller_text(&extension_reason_code, 100)
            || !valid_caller_text(&extension_reason, 4_000)
            || extension_business_days <= 0
        {
            return Err(PrivacyCommandError::InvalidCommand);
        }

        Ok(Self {
            extension_reason_code,
            extension_reason,
            extension_business_days,
        })
    }

    pub fn extension_reason_code(&self) -> &str {
        &self.extension_reason_code
    }

    pub fn extension_reason(&self) -> &str {
        &self.extension_reason
    }

    pub const fn extension_business_days(&self) -> i32 {
        self.extension_business_days
    }
}

fn valid_caller_text(value: &str, maximum_characters: usize) -> bool {
    (1..=maximum_characters).contains(&value.chars().count())
        && !value.trim().is_empty()
        && !value.contains('\0')
        && !value.chars().any(char::is_control)
}

#[cfg(test)]
#[path = "privacy_extension_tests.rs"]
mod tests;
