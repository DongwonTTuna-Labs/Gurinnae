use time::{OffsetDateTime, error::Format, format_description::well_known::Rfc3339};

pub(crate) fn event_occurred_at(value: OffsetDateTime) -> Result<String, Format> {
    value.format(&Rfc3339)
}

#[cfg(test)]
mod tests {
    use time::{OffsetDateTime, format_description::well_known::Rfc3339};

    use super::event_occurred_at;

    #[test]
    fn event_occurred_at_is_a_round_trip_rfc3339_string() {
        let occurred_at = OffsetDateTime::from_unix_timestamp_nanos(1_775_000_005_375_127_000)
            .expect("test timestamp must be representable");
        let encoded = event_occurred_at(occurred_at).expect("test timestamp must format");

        assert!(
            serde_json::to_value(&encoded)
                .expect("string serialization")
                .is_string()
        );
        assert_eq!(
            OffsetDateTime::parse(&encoded, &Rfc3339).expect("RFC 3339 timestamp"),
            occurred_at
        );
    }
}
