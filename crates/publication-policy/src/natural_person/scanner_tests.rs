#[cfg(test)]
use super::detector::{
    ADDITIONAL_TITLE_SPACE_CHARACTERS, IGNORED_NAME_CHARACTERS, LEGACY_TITLE_SEPARATOR_CHARACTERS,
    NAME_PUNCTUATION_SEPARATOR_CHARACTERS, NAME_WHITESPACE_CHARACTERS,
};
#[cfg(test)]
use super::{
    NATURAL_PERSON_RULESET_VERSION, NaturalPersonFindingBasis, NaturalPersonScanError,
    PublicTextNode, RegisteredPersonName, RegisteredPersonNameError,
    canonical_registered_person_name, natural_person_ruleset_sha256, public_text_sha256,
    scan_public_text,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

const GUARD_SCHEMA: &str =
    include_str!("../../../../specs/schemas/named-individual-publication-guard.schema.json");
const GUARD_FIXTURES: &[&str] = &[
    include_str!(
        "../../../../fixtures/publication-guards/named-individual-awaiting-legal-review.guard.json"
    ),
    include_str!(
        "../../../../fixtures/publication-guards/named-individual-official-disposition.guard.json"
    ),
];
const B2_MIGRATION: &str =
    include_str!("../../../../db/migrations/0044_b2_natural_person_detection_digest_closure.sql");

fn registered(value: &str) -> Result<RegisteredPersonName<'_>, RegisteredPersonNameError> {
    RegisteredPersonName::new(value)
}

fn sql_codepoints(function_name: &str) -> Result<Vec<u32>, &'static str> {
    let declaration = format!("CREATE OR REPLACE FUNCTION editorial.{function_name}()");
    let function = B2_MIGRATION
        .split_once(&declaration)
        .map(|(_, tail)| tail)
        .ok_or("SQL character catalog function is missing")?;
    let array = function
        .split_once("ARRAY[")
        .map(|(_, tail)| tail)
        .and_then(|tail| tail.split_once("]::integer[]").map(|(value, _)| value))
        .ok_or("SQL character catalog array is missing")?;
    array
        .split(',')
        .map(str::trim)
        .map(|value| value.parse().map_err(|_| "SQL codepoint is invalid"))
        .collect()
}

#[test]
fn recursively_scans_registered_names_without_returning_pii() -> TestResult {
    let document = PublicTextNode::object(vec![
        ("summary", PublicTextNode::text("기관 공개 기록")),
        (
            "claims",
            PublicTextNode::array(vec![PublicTextNode::object(vec![(
                "text_ko",
                PublicTextNode::text("📌 홍 길동 관련 공식 처분을 인용함"),
            )])]),
        ),
    ]);
    let assessment = scan_public_text(&document, &[registered("홍길동")?])?;

    assert!(assessment.blocks_publication_without_override());
    assert_eq!(assessment.findings.len(), 1);
    let finding = &assessment.findings[0];
    assert_eq!(finding.path, "/claims/0/text_ko");
    assert_eq!(finding.start_utf16, 3);
    assert_eq!(finding.end_utf16, 7);
    assert_eq!(
        finding.basis,
        NaturalPersonFindingBasis::RegisteredPersonExact
    );
    assert!(!finding.permits_identity_merge());
    let wire = serde_json::to_string(finding)?;
    assert!(!wire.contains("홍"));
    assert!(!wire.contains("personId"));
    Ok(())
}

#[test]
fn registered_person_exact_match_and_unrelated_registered_name_are_distinct() -> TestResult {
    let positive = PublicTextNode::object(vec![(
        "summary",
        PublicTextNode::text("계약 담당 홍·길 동 확인"),
    )]);
    let registered_people = [registered("홍길동")?];
    let assessment = scan_public_text(&positive, &registered_people)?;

    assert_eq!(assessment.findings.len(), 1);
    assert_eq!(assessment.findings[0].path, "/summary");
    assert_eq!(assessment.findings[0].start_utf16, 6);
    assert_eq!(assessment.findings[0].end_utf16, 11);
    assert_eq!(
        assessment.findings[0].basis,
        NaturalPersonFindingBasis::RegisteredPersonExact
    );
    assert_eq!(
        assessment.findings[0].ruleset_version,
        NATURAL_PERSON_RULESET_VERSION
    );

    let negative = PublicTextNode::text("등록 인물과 무관한 김하늘 계약 기록");
    assert!(
        scan_public_text(&negative, &registered_people)?
            .findings
            .is_empty()
    );
    Ok(())
}

#[test]
fn title_adjacent_hangul_name_blocks_even_when_ambiguous() -> TestResult {
    let document = PublicTextNode::object(vec![(
        "summary",
        PublicTextNode::text("대표이사 김하늘은 자료에 답변함"),
    )]);
    let assessment = scan_public_text(&document, &[])?;

    assert_eq!(assessment.findings.len(), 1);
    assert_eq!(assessment.findings[0].start_utf16, 5);
    assert_eq!(assessment.findings[0].end_utf16, 8);
    assert_eq!(
        assessment.findings[0].basis,
        NaturalPersonFindingBasis::TitleAdjacentKoreanName
    );
    Ok(())
}

#[test]
fn unicode_normalization_cannot_hide_a_registered_or_title_adjacent_name() -> TestResult {
    let decomposed_name = "김하늘";
    let registered_document = PublicTextNode::text(decomposed_name);
    let registered_assessment = scan_public_text(&registered_document, &[registered("김하늘")?])?;
    assert_eq!(registered_assessment.findings.len(), 1);
    assert_eq!(registered_assessment.findings[0].start_utf16, 0);
    assert_eq!(registered_assessment.findings[0].end_utf16, 8);

    let titled_text = format!("대표이사 {decomposed_name}은 답변함");
    let titled_document = PublicTextNode::text(&titled_text);
    let titled_assessment = scan_public_text(&titled_document, &[])?;
    assert_eq!(titled_assessment.findings.len(), 1);
    assert_eq!(
        titled_assessment.findings[0].basis,
        NaturalPersonFindingBasis::TitleAdjacentKoreanName
    );
    Ok(())
}

#[test]
fn test_only_zero_width_characters_cannot_hide_a_synthetic_name() -> TestResult {
    for ignored in IGNORED_NAME_CHARACTERS {
        for repeat in [1, 24] {
            let obscured_name = format!("테스트{}인", ignored.to_string().repeat(repeat));
            let registered_document = PublicTextNode::text(&obscured_name);
            let registered_assessment =
                scan_public_text(&registered_document, &[registered("테스트인")?])?;
            assert_eq!(
                registered_assessment.findings.len(),
                1,
                "U+{:04X} repeated {repeat} times",
                *ignored as u32
            );
            assert_eq!(registered_assessment.findings[0].start_utf16, 0);
            assert_eq!(
                registered_assessment.findings[0].end_utf16,
                4 + repeat,
                "U+{:04X} registered finding must retain the original UTF-16 span",
                *ignored as u32
            );

            let titled_text = format!("장관 {obscured_name}");
            let titled_document = PublicTextNode::text(&titled_text);
            let titled_assessment = scan_public_text(&titled_document, &[])?;
            assert_eq!(
                titled_assessment.findings.len(),
                1,
                "U+{:04X} repeated {repeat} times",
                *ignored as u32
            );
            assert_eq!(
                titled_assessment.findings[0].basis,
                NaturalPersonFindingBasis::TitleAdjacentKoreanName
            );
            assert_eq!(titled_assessment.findings[0].start_utf16, 3);
            assert_eq!(
                titled_assessment.findings[0].end_utf16,
                7 + repeat,
                "U+{:04X} title-adjacent finding must retain the original UTF-16 span",
                *ignored as u32
            );
            if repeat == 1 {
                println!(
                    "B2_RUST_IGNORABLE U+{:04X} PASS registered=1 registered_utf16=0..5 title_adjacent=1 title_utf16=3..8",
                    *ignored as u32
                );
            }
        }
    }
    Ok(())
}

#[test]
fn test_only_explicit_unicode_spaces_separate_a_title_and_synthetic_name() -> TestResult {
    for separator in ADDITIONAL_TITLE_SPACE_CHARACTERS {
        let text = format!("장관{separator}테스트인");
        let document = PublicTextNode::text(&text);
        let assessment = scan_public_text(&document, &[])?;
        assert_eq!(
            assessment.findings.len(),
            1,
            "U+{:04X} must separate the title and name",
            *separator as u32
        );
        assert_eq!(
            assessment.findings[0].basis,
            NaturalPersonFindingBasis::TitleAdjacentKoreanName
        );
        assert_eq!(assessment.findings[0].start_utf16, 3);
        assert_eq!(assessment.findings[0].end_utf16, 7);
        println!(
            "B2_RUST_TITLE_SPACE U+{:04X} PASS title_adjacent=1 title_utf16=3..7",
            *separator as u32
        );
    }
    Ok(())
}

#[test]
fn test_only_quoted_title_and_synthetic_name_remain_adjacent() -> TestResult {
    let document = PublicTextNode::text("「대표이사」 \"테스트인\"");
    let assessment = scan_public_text(&document, &[])?;

    assert_eq!(assessment.findings.len(), 1);
    assert_eq!(assessment.findings[0].start_utf16, 8);
    assert_eq!(assessment.findings[0].end_utf16, 12);
    assert_eq!(
        assessment.findings[0].basis,
        NaturalPersonFindingBasis::TitleAdjacentKoreanName
    );
    Ok(())
}

#[test]
fn exported_registered_name_normalization_is_the_scanner_canonical_form() -> TestResult {
    assert_eq!(canonical_registered_person_name(" 김·하 늘 "), "김하늘");
    let document = PublicTextNode::text("김하늘");
    let assessment = scan_public_text(&document, &[registered(" 김·하 늘 ")?])?;
    assert_eq!(assessment.findings.len(), 1);
    assert_eq!(assessment.findings[0].start_utf16, 0);
    assert_eq!(assessment.findings[0].end_utf16, 3);
    Ok(())
}

#[test]
fn ordinary_korean_words_and_unregistered_names_do_not_match() -> TestResult {
    let document = PublicTextNode::object(vec![
        ("summary", PublicTextNode::text("대표적인 사례를 공개함")),
        ("detail", PublicTextNode::text("가상기관 계약 기록")),
        ("name", PublicTextNode::text("홍길동")),
    ]);
    let assessment = scan_public_text(&document, &[])?;
    assert!(assessment.findings.is_empty());
    Ok(())
}

#[test]
fn canonical_digest_is_order_independent_for_object_fields_and_exact_for_text() -> TestResult {
    let left = PublicTextNode::object(vec![
        ("summary", PublicTextNode::text("같은 내용")),
        ("title", PublicTextNode::text("제목")),
    ]);
    let reordered = PublicTextNode::object(vec![
        ("title", PublicTextNode::text("제목")),
        ("summary", PublicTextNode::text("같은 내용")),
    ]);
    let changed = PublicTextNode::object(vec![
        ("summary", PublicTextNode::text("같은 내용 ")),
        ("title", PublicTextNode::text("제목")),
    ]);

    assert_eq!(public_text_sha256(&left)?, public_text_sha256(&reordered)?);
    assert_ne!(public_text_sha256(&left)?, public_text_sha256(&changed)?);
    Ok(())
}

#[test]
fn ruleset_digest_and_finding_wire_shape_are_versioned() -> TestResult {
    assert_eq!(NATURAL_PERSON_RULESET_VERSION, "ko-named-individual-v1");
    assert_eq!(natural_person_ruleset_sha256().len(), 64);
    let document = PublicTextNode::text("이현우 사장");
    let assessment = scan_public_text(&document, &[])?;
    let wire = serde_json::to_value(&assessment)?;
    assert_eq!(wire["rulesetVersion"], NATURAL_PERSON_RULESET_VERSION);
    assert_eq!(wire["findings"][0]["basis"], "TITLE_ADJACENT_KOREAN_NAME");
    assert!(wire["findings"][0].get("matchedText").is_none());
    Ok(())
}

#[test]
fn schema_and_guard_fixture_ruleset_digests_match_the_rust_derivation() -> TestResult {
    let derived_ruleset = natural_person_ruleset_sha256();
    let schema: serde_json::Value = serde_json::from_str(GUARD_SCHEMA)?;
    assert_eq!(
        schema
            .pointer("/properties/assessment/properties/rulesetSha256/const")
            .and_then(serde_json::Value::as_str),
        Some(derived_ruleset.as_str()),
        "guard schema rulesetSha256 must be Rust-derived"
    );

    for fixture_source in GUARD_FIXTURES {
        let fixture: serde_json::Value = serde_json::from_str(fixture_source)?;
        let expected_ruleset = fixture
            .pointer("/assessment/rulesetSha256")
            .and_then(serde_json::Value::as_str);
        assert_eq!(
            expected_ruleset,
            Some(derived_ruleset.as_str()),
            "guard fixture rulesetSha256 must be Rust-derived"
        );
    }
    assert_eq!(
        B2_MIGRATION.matches(&derived_ruleset).count(),
        2,
        "0044 policy CHECK and immutable v3 row must use the Rust-derived digest"
    );
    Ok(())
}

#[test]
fn rust_and_sql_explicit_character_catalogs_are_identical() -> TestResult {
    let catalogs = [
        ("r6d_ignored_name_codepoints_f9_v1", IGNORED_NAME_CHARACTERS),
        (
            "r6d_name_whitespace_codepoints_f9_v1",
            NAME_WHITESPACE_CHARACTERS,
        ),
        (
            "r6d_name_punctuation_codepoints_f9_v1",
            NAME_PUNCTUATION_SEPARATOR_CHARACTERS,
        ),
        (
            "r6d_legacy_title_separator_codepoints_f9_v1",
            LEGACY_TITLE_SEPARATOR_CHARACTERS,
        ),
        (
            "r6d_additional_title_space_codepoints_f9_v1",
            ADDITIONAL_TITLE_SPACE_CHARACTERS,
        ),
    ];
    for (function_name, rust_characters) in catalogs {
        assert_eq!(
            sql_codepoints(function_name)?,
            rust_characters
                .iter()
                .map(|character| *character as u32)
                .collect::<Vec<_>>(),
            "Rust and SQL catalogs differ for {function_name}"
        );
    }
    Ok(())
}

#[test]
fn duplicate_object_paths_fail_closed_without_echoing_text() -> TestResult {
    let document = PublicTextNode::object(vec![
        ("summary", PublicTextNode::text("홍길동")),
        ("summary", PublicTextNode::text("다른 값")),
    ]);
    assert_eq!(
        scan_public_text(&document, &[registered("홍길동")?]),
        Err(NaturalPersonScanError::DuplicateField {
            path: "/summary".to_owned()
        })
    );
    Ok(())
}
