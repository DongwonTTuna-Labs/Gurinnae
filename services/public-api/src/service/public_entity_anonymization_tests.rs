#[cfg(test)]
mod public_entity_anonymization_tests {
    #[test]
    fn direct_entity_reads_exclude_terminally_anonymized_rows() {
        let entities = include_str!("entities.rs");
        for predicate in [
            "FROM public.agencies a WHERE a.name IS NOT NULL AND",
            "FROM public.suppliers s WHERE s.name IS NOT NULL AND",
            "FROM public.agencies WHERE id=$1 AND name IS NOT NULL",
            "FROM public.suppliers WHERE id=$1 AND name IS NOT NULL",
        ] {
            assert!(
                entities.contains(predicate),
                "missing predicate: {predicate}"
            );
        }
    }

    #[test]
    fn search_and_export_exclude_only_direct_null_name_entity_rows() {
        for source in [include_str!("public_search.rs"), include_str!("exports.rs")] {
            assert!(
                source.contains("FROM public.agencies a WHERE a.name IS NOT NULL AND a.name ILIKE")
            );
            assert!(source.contains("FROM public.suppliers WHERE name IS NOT NULL AND name ILIKE"));
            assert!(source.contains("SELECT 'CONTRACT',c.id::text,c.title"));
        }
    }

    #[test]
    fn coverage_counts_only_publicly_visible_entities() {
        let cases = include_str!("cases.rs");
        assert!(cases.contains("count(*) FROM public.agencies WHERE name IS NOT NULL"));
        assert!(cases.contains("count(*) FROM public.suppliers WHERE name IS NOT NULL"));
    }

    #[test]
    fn entity_ref_keeps_required_name_field_nullable_without_placeholder() {
        let public_openapi = include_str!("../../../../specs/api/public-api.openapi.yaml");
        let control_openapi = include_str!("../../../../specs/api/control-api.openapi.yaml");
        let resource_schemas = include_str!("../../../../specs/api/resource-schemas.yaml");
        let public_entity_ref = "    EntityRef:\n      type: object\n      additionalProperties: false\n      properties:\n        id:\n          type: string\n          format: uuid\n        name:\n          type:\n          - string\n          - 'null'";
        let resource_entity_ref = "  EntityRef:\n    schema:\n      type: object\n      additionalProperties: false\n      properties:\n        id:\n          type: string\n          format: uuid\n        name:\n          type:\n          - string\n          - 'null'";

        assert!(public_openapi.contains(public_entity_ref));
        assert!(control_openapi.contains(public_entity_ref));
        assert!(resource_schemas.contains(resource_entity_ref));

        let mapper = include_str!("public_rows.rs");
        assert!(mapper.contains("\"name\": name,"));
        assert!(!mapper.contains("공개 식별자 미상"));
    }
}
