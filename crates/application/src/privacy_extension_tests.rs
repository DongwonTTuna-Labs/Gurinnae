use super::*;

fn valid_input() -> Option<PrivacyExtensionInput> {
    PrivacyExtensionInput::try_new(
        "MORE_TIME_REQUIRED",
        "Records require additional review.",
        5,
    )
    .ok()
}

#[test]
fn privacy_extension_preserves_the_complete_transport_payload() {
    let Some(extension) = valid_input() else {
        assert!(false, "valid privacy extension fixture");
        return;
    };

    assert_eq!(extension.extension_reason_code(), "MORE_TIME_REQUIRED");
    assert_eq!(
        extension.extension_reason(),
        "Records require additional review."
    );
    assert_eq!(extension.extension_business_days(), 5);
}

#[test]
fn privacy_extension_accepts_text_boundaries_and_defers_the_policy_maximum() {
    let Ok(extension) =
        PrivacyExtensionInput::try_new("C".repeat(100), "R".repeat(4_000), i32::MAX)
    else {
        assert!(false, "valid boundary privacy extension fixture");
        return;
    };

    assert_eq!(extension.extension_reason_code().chars().count(), 100);
    assert_eq!(extension.extension_reason().chars().count(), 4_000);
    assert_eq!(extension.extension_business_days(), i32::MAX);
}

#[test]
fn privacy_extension_rejects_empty_and_overlong_text() {
    for (reason_code, reason) in [
        (String::new(), "valid".to_owned()),
        ("C".repeat(101), "valid".to_owned()),
        ("VALID".to_owned(), String::new()),
        ("VALID".to_owned(), "R".repeat(4_001)),
    ] {
        assert!(PrivacyExtensionInput::try_new(reason_code, reason, 1).is_err());
    }
}

#[test]
fn privacy_extension_rejects_trimmed_empty_control_and_nul_text() {
    for reason_code in ["   ", "CODE\n", "CODE\0SUFFIX"] {
        assert!(PrivacyExtensionInput::try_new(reason_code, "valid", 1).is_err());
    }
    for reason in ["\t", "valid\rtext", "valid\0text"] {
        assert!(PrivacyExtensionInput::try_new("VALID", reason, 1).is_err());
    }
}

#[test]
fn privacy_extension_rejects_non_positive_business_days() {
    for business_days in [i32::MIN, -1, 0] {
        assert!(PrivacyExtensionInput::try_new("VALID", "valid", business_days).is_err());
    }
}
