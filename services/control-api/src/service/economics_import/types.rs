use super::*;
use std::ops::Deref;

/// A composite attribute that must be present on the wire even when its value
/// is SQL NULL.  Plain `Option<T>` would also accept an omitted key, which
/// would violate the complete row-valued economics import contract.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub(super) struct RequiredNullable<T>(Option<T>);

#[derive(Deserialize)]
#[serde(untagged)]
enum RequiredNullableWire<T> {
    Value(T),
    Null(()),
}

impl<'de, T> Deserialize<'de> for RequiredNullable<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = RequiredNullableWire::deserialize(deserializer)?;
        Ok(Self(match value {
            RequiredNullableWire::Value(value) => Some(value),
            RequiredNullableWire::Null(()) => None,
        }))
    }
}

impl<T> RequiredNullable<T> {
    pub(super) const fn as_option(&self) -> &Option<T> {
        &self.0
    }
}

impl<T> Deref for RequiredNullable<T> {
    type Target = Option<T>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(try_from = "String")]
pub(super) struct Sha256Digest(String);

impl TryFrom<String> for Sha256Digest {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if is_sha256(&value) {
            Ok(Self(value))
        } else {
            Err("invalid sha256 digest")
        }
    }
}

impl Sha256Digest {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(try_from = "String")]
pub(super) struct DateText(String);

impl TryFrom<String> for DateText {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let format = time::format_description::parse("[year]-[month]-[day]")
            .map_err(|_| "invalid date format")?;
        Date::parse(&value, &format).map_err(|_| "invalid date")?;
        Ok(Self(value))
    }
}

impl DateText {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(try_from = "String")]
pub(super) struct DateTimeText(String);

impl TryFrom<String> for DateTimeText {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        OffsetDateTime::parse(&value, &Rfc3339).map_err(|_| "invalid datetime")?;
        Ok(Self(value))
    }
}

impl DateTimeText {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}
