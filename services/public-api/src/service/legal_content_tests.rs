#[cfg(test)]
mod legal_content_tests {
    use super::*;

    #[test]
    fn generated_launch_blocked_documents_are_not_returned_as_public_success() {
        for kind in [LegalDocumentKind::Privacy, LegalDocumentKind::Terms] {
            assert!(matches!(
                published_legal_document(kind),
                Err(ServiceError::Persistence)
            ));
        }
    }

    #[test]
    fn legal_document_validation_rejects_missing_duplicate_and_unknown_ids() {
        let canonical = ["first", "second"];
        for sections in [
            vec![section("first")],
            vec![section("first"), section("first")],
            vec![section("first"), section("unknown")],
        ] {
            let document = LegalDocument {
                status: "DRAFT".to_owned(),
                sections,
            };
            assert!(matches!(
                validate_legal_document(&document, &canonical),
                Err(ServiceError::Persistence)
            ));
        }
    }

    #[test]
    fn retention_schedules_are_nonempty_current_sorted_and_closed() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::days(1);
        let mut valid = schedule("AGENCY_MASTER", now);
        assert!(retention_schedule_values(std::slice::from_ref(&valid), now).is_ok());

        valid.review_expires_at = now;
        assert!(matches!(
            retention_schedule_values(std::slice::from_ref(&valid), now),
            Err(ServiceError::Persistence)
        ));

        let mut malformed = schedule("AGENCY_MASTER", now);
        malformed.terminal_action = "PRESERVE_FOREVER".to_owned();
        assert!(matches!(
            retention_schedule_values(std::slice::from_ref(&malformed), now),
            Err(ServiceError::Persistence)
        ));
        malformed = schedule("AGENCY_MASTER", now);
        malformed.schedule_digest = "A".repeat(64);
        assert!(matches!(
            retention_schedule_values(std::slice::from_ref(&malformed), now),
            Err(ServiceError::Persistence)
        ));
        malformed = schedule("AGENCY_MASTER", now);
        malformed.active_duration_seconds = Some(-1);
        assert!(matches!(
            retention_schedule_values(std::slice::from_ref(&malformed), now),
            Err(ServiceError::Persistence)
        ));
        malformed = schedule("AGENCY_MASTER", now);
        malformed.effective_at = now + time::Duration::seconds(1);
        assert!(matches!(
            retention_schedule_values(std::slice::from_ref(&malformed), now),
            Err(ServiceError::Persistence)
        ));
        assert!(matches!(
            retention_schedule_values(&[], now),
            Err(ServiceError::Persistence)
        ));

        let duplicate = schedule("SUPPLIER_MASTER", now);
        assert!(matches!(
            retention_schedule_values(&[schedule("SUPPLIER_MASTER", now), duplicate], now),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn terms_require_current_approved_retention_schedule_authority() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::days(1);
        let mut expired = schedule("AGENCY_MASTER", now);
        expired.review_expires_at = now;
        let mut invalid = schedule("AGENCY_MASTER", now);
        invalid.schedule_digest = "A".repeat(64);
        for rows in [Vec::new(), vec![expired], vec![invalid]] {
            assert!(matches!(
                render_legal_document(LegalDocumentKind::Terms, document("service"), &rows, now,),
                Err(ServiceError::Persistence)
            ));
        }

        let rows = [schedule("AGENCY_MASTER", now)];
        let rendered =
            render_legal_document(LegalDocumentKind::Terms, document("service"), &rows, now);
        assert!(rendered.as_ref().is_ok_and(|value| {
            value["id"]["id"] == "terms"
                && value["data"]["sections"][0]["id"] == "service"
                && value["data"]["retentionSchedules"][0]["recordClass"]
                    == "AGENCY_MASTER"
                && value["data"].as_object().is_some_and(|data| {
                    data.keys().map(String::as_str).collect::<BTreeSet<_>>()
                        == BTreeSet::from(["retentionSchedules", "sections", "status"])
                })
        }));
    }

    #[test]
    fn both_legal_documents_contain_each_approved_schedule_field() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::days(1);
        for kind in [LegalDocumentKind::Privacy, LegalDocumentKind::Terms] {
            let rows = [schedule("AGENCY_MASTER", now)];
            let rendered = render_legal_document(kind, document("controller"), &rows, now);
            assert!(rendered.as_ref().is_ok_and(|value| {
                value["data"]["retentionSchedules"][0]
                    .as_object()
                    .is_some_and(|schedule| {
                        schedule.keys().map(String::as_str).collect::<BTreeSet<_>>()
                            == BTreeSet::from([
                                "activeDurationSeconds",
                                "backupDurationSeconds",
                                "effectiveAt",
                                "lawfulBasis",
                                "purpose",
                                "recordClass",
                                "reviewExpiresAt",
                                "scheduleDigest",
                                "terminalAction",
                                "triggerKind",
                            ])
                    })
            }));
        }
    }

    fn schedule(
        record_class: &str,
        observed_at: OffsetDateTime,
    ) -> ActiveApprovedRetentionScheduleRow {
        ActiveApprovedRetentionScheduleRow {
            record_class: record_class.to_owned(),
            purpose: "공개 조달 기록의 보존 관리".to_owned(),
            lawful_basis: "공익 조달 감시".to_owned(),
            trigger_kind: "LAST_MATERIAL_USE_AT".to_owned(),
            active_duration_seconds: Some(157_788_000),
            backup_duration_seconds: Some(31_557_600),
            terminal_action: "ANONYMIZE".to_owned(),
            effective_at: OffsetDateTime::UNIX_EPOCH,
            review_expires_at: observed_at + time::Duration::days(1),
            schedule_digest: "a".repeat(64),
        }
    }

    fn section(id: &str) -> LegalSection {
        LegalSection {
            id: id.to_owned(),
            heading: "제목".to_owned(),
            body: "본문".to_owned(),
        }
    }

    fn document(section_id: &str) -> LegalDocument {
        LegalDocument {
            status: "PUBLISHED".to_owned(),
            sections: vec![section(section_id)],
        }
    }
}
