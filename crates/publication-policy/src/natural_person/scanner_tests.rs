#[cfg(test)]
use super::{
    NATURAL_PERSON_RULESET_VERSION, NaturalPersonFindingBasis, NaturalPersonScanError,
    PublicTextNode, RegisteredPersonName, RegisteredPersonNameError,
    canonical_registered_person_name, natural_person_ruleset_sha256, public_text_sha256,
    scan_public_text,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn registered(value: &str) -> Result<RegisteredPersonName<'_>, RegisteredPersonNameError> {
    RegisteredPersonName::new(value)
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
    for ignored in ['\u{200b}', '\u{feff}', '\u{00ad}'] {
        for repeat in [1, 24] {
            let obscured_name = format!("테{}스트인", ignored.to_string().repeat(repeat));
            let registered_document = PublicTextNode::text(&obscured_name);
            let registered_assessment =
                scan_public_text(&registered_document, &[registered("테스트인")?])?;
            assert_eq!(
                registered_assessment.findings.len(),
                1,
                "U+{:04X} repeated {repeat} times",
                ignored as u32
            );

            let titled_text = format!("대표이사 {obscured_name}은 답변함");
            let titled_document = PublicTextNode::text(&titled_text);
            let titled_assessment = scan_public_text(&titled_document, &[])?;
            assert_eq!(
                titled_assessment.findings.len(),
                1,
                "U+{:04X} repeated {repeat} times",
                ignored as u32
            );
            assert_eq!(
                titled_assessment.findings[0].basis,
                NaturalPersonFindingBasis::TitleAdjacentKoreanName
            );
        }
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
    assert_eq!(
        natural_person_ruleset_sha256(),
        "3b6449ab94c887b9b31ddb10481acfc132d4db29fcbadb394fa88c7305ec09c4"
    );
    let document = PublicTextNode::text("이현우 사장");
    let assessment = scan_public_text(&document, &[])?;
    let wire = serde_json::to_value(&assessment)?;
    assert_eq!(wire["rulesetVersion"], NATURAL_PERSON_RULESET_VERSION);
    assert_eq!(wire["findings"][0]["basis"], "TITLE_ADJACENT_KOREAN_NAME");
    assert!(wire["findings"][0].get("matchedText").is_none());
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
