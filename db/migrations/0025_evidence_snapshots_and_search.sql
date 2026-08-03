BEGIN;
-- Source-derived 0025 physical registry: 36 relations.
-- Existing 0001..0024 migrations are byte-immutable; this migration is additive.
SET LOCAL search_path = pg_catalog, public;
CREATE OR REPLACE FUNCTION ops.digest_array_is_sorted_unique(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) > 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value !~ '^[0-9a-f]{64}$') AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE "C") $$;
ALTER FUNCTION ops.digest_array_is_sorted_unique(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.digest_array_is_sorted_unique(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.text_array_is_sorted_unique(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) >= 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE "C") $$;
ALTER FUNCTION ops.text_array_is_sorted_unique(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.text_array_is_sorted_unique(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.connector_operation_contract_is_valid(text,text,text,text,char(64),text,char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT ($1 = 'alio' AND $2 = 'alio-manifest' AND $3 = 'MANIFEST_DOCUMENTS_ARRAY' AND $4 = 'manifest-root.v1' AND $6 = '13.0.0' AND $7 = '5617358308396d8de06c64971124cf6680aa9e480f8db59dce63de7aa31fe2af' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'alio' AND $2 = 'alio-document' AND $3 = 'MANIFEST_ORDER' AND $4 = 'manifest-order.v1' AND $6 = '13.0.0' AND $7 = '5617358308396d8de06c64971124cf6680aa9e480f8db59dce63de7aa31fe2af' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'audit-results' AND $2 = 'audit-results-manifest' AND $3 = 'MANIFEST_DOCUMENTS_ARRAY' AND $4 = 'manifest-root.v1' AND $6 = '13.0.0' AND $7 = '497973dbc4c21487527a8686544b128c2492b1b6772990332ec11fe22511ed1b' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'audit-results' AND $2 = 'audit-result-document' AND $3 = 'MANIFEST_ORDER' AND $4 = 'manifest-order.v1' AND $6 = '13.0.0' AND $7 = '497973dbc4c21487527a8686544b128c2492b1b6772990332ec11fe22511ed1b' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-goods-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-goods-detail' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-goods-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-goods-delete' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-construction-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-construction-detail' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-construction-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-construction-delete' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-service-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-service-detail' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-service-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-service-delete' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-foreign-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-foreign-detail' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-foreign-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-contracts' AND $2 = 'contract-foreign-delete' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ff73547c58a9c6b6fdcc8a38d31ab524762b9affec8c3986ca82714ba9c16d22' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-goods-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-goods-search' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-goods-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-construction-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-construction-search' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-construction-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-service-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-service-search' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-service-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-foreign-list' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-foreign-search' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-foreign-change' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-goods-base-amount' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-construction-base-amount' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-service-base-amount' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-license-restriction' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'koneps-notices' AND $2 = 'notice-region-eligibility' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = '7dd056ed1c40f364386b90a308e91035e6d5d6ab63a449b2b1174929bc0612da' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'local-finance' AND $2 = 'local-finance-disclosures' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'f435335ad64b6608391c53be86fc09e34969fa13c40be2785c41722d31c466e5' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'local-finance' AND $2 = 'local-finance-subsidies' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'f435335ad64b6608391c53be86fc09e34969fa13c40be2785c41722d31c466e5' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'local-finance' AND $2 = 'local-finance-statistics' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'f435335ad64b6608391c53be86fc09e34969fa13c40be2785c41722d31c466e5' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'open-dart' AND $2 = 'dart-corp-code' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'ea04d0cf53ce751f8d009412ddae2466f4e65f63f9edb68380ea9fb17f252124' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'open-dart' AND $2 = 'dart-company' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'ea04d0cf53ce751f8d009412ddae2466f4e65f63f9edb68380ea9fb17f252124' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'open-dart' AND $2 = 'dart-disclosures' AND $3 = 'PAGE_NUMBER' AND $4 = 'page-number.total-count.v1' AND $6 = '13.0.0' AND $7 = 'ea04d0cf53ce751f8d009412ddae2466f4e65f63f9edb68380ea9fb17f252124' AND $5 ~ '^[0-9a-f]{64}$') OR ($1 = 'open-dart' AND $2 = 'dart-financial-statements' AND $3 = 'NONE' AND $4 = 'single-response.v1' AND $6 = '13.0.0' AND $7 = 'ea04d0cf53ce751f8d009412ddae2466f4e65f63f9edb68380ea9fb17f252124' AND $5 ~ '^[0-9a-f]{64}$') $$;
ALTER FUNCTION ops.connector_operation_contract_is_valid(text,text,text,text,char(64),text,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.connector_operation_contract_is_valid(text,text,text,text,char(64),text,char(64)) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_tool_schema_contract_is_valid(text,char(64),char(64)) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT ($1 = 'claim.language_check' AND $2 = '0eff4fa492ebc9664f49ecf871880c7f776050c36e9d4ddac1a3d4482600e615' AND $3 = 'ac77f413e976813197b57db66a5737178c87f51ba7d67b19bc31aa80b7c0dbf6') OR ($1 = 'contract.find_comparables' AND $2 = '84fc62d88f8c6d61717fcf7e025cc4e7b4825703cb147d207ba6a92d8875a5c0' AND $3 = '15f512d7b8d1ddb98c09e04ece72c0907e29c21a38501bb539d86e43881e64fe') OR ($1 = 'entity.lookup' AND $2 = '19133149878dbbf54ef7865f1822c77ea2c31aac8bcfcc377ad4869e18bb713d' AND $3 = '0dc88f3b5cac41877326f3f6cbf5a86a8859e4124bdc387adc7816c3444256a1') OR ($1 = 'evidence.read' AND $2 = '71ba7e5b3d0867e7ac36354f82d42cf8533c1ed93b49426f248cc9147a6b8bde' AND $3 = 'ec19aa983c3c786da78f4e2bc41e6398c6af24ae8d3506ee4cf0848a4a0fa4e0') OR ($1 = 'evidence.search' AND $2 = 'd92f236d62ab15ddb3ba12af5f63079e2293057d7d5d21f5d43280306ca54c42' AND $3 = 'cc44ee052c404fae5fd5945e483d60966e76b1f44c1ebfea576b19444bc651ca') OR ($1 = 'response.read' AND $2 = '87e0332aed2c7de8f604db95a629159856426e3f8e4f2649194c5148716d74ee' AND $3 = 'f751a34a8f78407894ff96605241928d3fecee2f7ff9b48ba130ecb48701855f') OR ($1 = 'rule.reproduce' AND $2 = 'ba0e45b6c03dad44a99299fc5a06058e740500dabe60f6af13cc77ebc5fd4147' AND $3 = '8104f45d77b0d576e986844e09b34370c642042ebe8d7c8a8dc3d68fbf9b21ff') OR ($1 = 'source.fetch' AND $2 = '8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67' AND $3 = '42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e') OR ($1 = 'source.locator_verify' AND $2 = '3470624bf89ed5d2116d7ef365b4dd017e822736f5b8d71189c7312653a5512f' AND $3 = 'd8ddd0649eb49c0f0d8bc9490fb48134cb383cfa671d53d6ad710be39bd998ad') $$;
ALTER FUNCTION ops.agent_tool_schema_contract_is_valid(text,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_tool_schema_contract_is_valid(text,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.agent_tool_schema_contract_is_valid(text,char(64),char(64)) TO gurine_analysis_worker;
CREATE OR REPLACE FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb) TO gurine_analysis_worker;
CREATE OR REPLACE FUNCTION ops.agent_proposal_payload_is_valid(text,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.agent_proposal_payload_is_valid(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_proposal_payload_is_valid(text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_provider_candidates_are_valid(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) BETWEEN 1 AND 8 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value !~ '^[a-z0-9][a-z0-9._-]{0,127}$') $$;
ALTER FUNCTION ops.agent_provider_candidates_are_valid(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_provider_candidates_are_valid(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.reject_mutation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.reject_mutation() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION core.enforce_normalization_run_lifecycle() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION core.enforce_normalization_run_lifecycle() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION core.enforce_dataset_snapshot_children() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION core.enforce_dataset_snapshot_children() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_agent_provider_turn_chain() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_agent_provider_turn_chain() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_agent_tool_call_lifecycle() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_agent_tool_call_lifecycle() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_agent_run_control_chain() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_agent_run_control_chain() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_agent_source_use_graph() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_agent_source_use_graph() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_agent_validation_and_citation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_agent_validation_and_citation() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION raw.enforce_research_artifact_promotion_graph() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION raw.enforce_research_artifact_promotion_graph() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION raw.enforce_source_page_completion() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION raw.enforce_source_page_completion() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION public.enforce_search_document_projection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION public.enforce_search_document_projection() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_search_document_projection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_search_document_projection() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION raw.enforce_asset_rights_sequence() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION raw.enforce_asset_rights_sequence() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.dataset_snapshot_selection_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.dataset_snapshot_selection_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.dataset_snapshot_selection_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.dataset_source_watermarks_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.dataset_source_watermarks_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.dataset_source_watermarks_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.dataset_normalization_versions_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.dataset_normalization_versions_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.dataset_normalization_versions_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.dataset_snapshot_manifest_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.dataset_snapshot_manifest_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.dataset_snapshot_manifest_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.dataset_snapshot_member_payload_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.dataset_snapshot_member_payload_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.dataset_snapshot_member_payload_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_provider_request_redacted_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_provider_request_redacted_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_provider_request_redacted_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_provider_response_redacted_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_provider_response_redacted_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_provider_response_redacted_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.provider_receipt_v2_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.provider_receipt_v2_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.provider_receipt_v2_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_tool_request_v2_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_tool_request_v2_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_tool_request_v2_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_tool_result_v2_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_tool_result_v2_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_tool_result_v2_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.research_safe_headers_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.research_safe_headers_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.research_safe_headers_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.research_redirect_chain_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.research_redirect_chain_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.research_redirect_chain_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_validation_failure_list_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_validation_failure_list_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_validation_failure_list_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.agent_validated_outcome_v2_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.agent_validated_outcome_v2_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_validated_outcome_v2_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.promotion_segment_bindings_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.promotion_segment_bindings_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.promotion_segment_bindings_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.promote_research_artifact_receipt_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.promote_research_artifact_receipt_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.promote_research_artifact_receipt_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_notice_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_notice_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_notice_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.award_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.award_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.award_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.supplier_party_ref_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.supplier_party_ref_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.supplier_party_ref_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.bidder_participation_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.bidder_participation_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bidder_participation_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_contract_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_contract_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_contract_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.contract_amendment_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.contract_amendment_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.contract_amendment_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_contract_line_item_revision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_contract_line_item_revision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_contract_line_item_revision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_contract_line_item_component_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_contract_line_item_component_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_contract_line_item_component_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.supplier_identity_candidate_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.supplier_identity_candidate_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.supplier_identity_candidate_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.supplier_identity_resolution_decision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.supplier_identity_resolution_decision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.supplier_identity_resolution_decision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.supplier_relationship_assertion_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.supplier_relationship_assertion_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.supplier_relationship_assertion_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_contract_filter_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_contract_filter_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_contract_filter_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.procurement_query_snapshot_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.procurement_query_snapshot_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.procurement_query_snapshot_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.response_request_scope_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.response_request_scope_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.response_request_scope_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.ordered_evidence_locator_ref_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.ordered_evidence_locator_ref_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.ordered_evidence_locator_ref_v1_is_valid(jsonb) FROM PUBLIC;
-- Existing-relation bridge: stable SourceAsset identity/revision.
ALTER TABLE raw.source_documents ADD COLUMN IF NOT EXISTS asset_id uuid;
ALTER TABLE raw.source_documents ADD COLUMN IF NOT EXISTS asset_revision bigint;
WITH ranked AS (
  SELECT id, first_value(id) OVER (PARTITION BY source_id, external_id ORDER BY retrieved_at, created_at, id) AS root_asset_id,
         row_number() OVER (PARTITION BY source_id, external_id ORDER BY retrieved_at, created_at, id) AS revision
  FROM raw.source_documents
)
UPDATE raw.source_documents d SET asset_id=ranked.root_asset_id, asset_revision=ranked.revision FROM ranked WHERE d.id=ranked.id;
ALTER TABLE raw.source_documents ALTER COLUMN asset_id SET NOT NULL;
ALTER TABLE raw.source_documents ALTER COLUMN asset_revision SET NOT NULL;
ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_revision_positive_ck CHECK (asset_revision > 0);
ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_revision_uk UNIQUE (asset_id, asset_revision);
ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_content_uk UNIQUE (asset_id, asset_revision, content_sha256);
ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_source_revision_uk UNIQUE (source_id, external_id, asset_revision);
ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_provenance_uk UNIQUE (id, asset_id, asset_revision, content_sha256);
DROP TRIGGER IF EXISTS source_documents_lifecycle_guard ON raw.source_documents;
CREATE OR REPLACE FUNCTION raw.enforce_source_document_lifecycle() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, raw, core, extensions, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'source_document_delete_forbidden' USING ERRCODE='55000'; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.source_id IS DISTINCT FROM OLD.source_id OR NEW.source_fetch_id IS DISTINCT FROM OLD.source_fetch_id OR NEW.external_id IS DISTINCT FROM OLD.external_id OR NEW.external_version IS DISTINCT FROM OLD.external_version OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url OR NEW.retrieved_at IS DISTINCT FROM OLD.retrieved_at OR NEW.source_published_at IS DISTINCT FROM OLD.source_published_at OR NEW.content_type IS DISTINCT FROM OLD.content_type OR NEW.content_sha256 IS DISTINCT FROM OLD.content_sha256 OR NEW.content_size_bytes IS DISTINCT FROM OLD.content_size_bytes OR NEW.object_key IS DISTINCT FROM OLD.object_key OR NEW.asset_id IS DISTINCT FROM OLD.asset_id OR NEW.asset_revision IS DISTINCT FROM OLD.asset_revision OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'source_document_identity_immutable' USING ERRCODE='55000';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT ((OLD.status = 'DISCOVERED' AND NEW.status IN ('FETCHED','QUARANTINED','REJECTED')) OR (OLD.status = 'FETCHED' AND NEW.status IN ('PARSED','QUARANTINED','REJECTED')) OR (OLD.status = 'QUARANTINED' AND NEW.status IN ('FETCHED','REJECTED'))) THEN
    RAISE EXCEPTION 'invalid_source_document_transition' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION raw.enforce_source_document_lifecycle() OWNER TO gurine_migrator;
CREATE TRIGGER source_documents_lifecycle_guard BEFORE UPDATE OR DELETE ON raw.source_documents FOR EACH ROW EXECUTE FUNCTION raw.enforce_source_document_lifecycle();
REVOKE INSERT, UPDATE, DELETE ON raw.source_documents FROM gurine_ingest_worker, gurine_analysis_worker, gurine_control_api, gurine_workflow_worker, gurine_document_extractor;
GRANT SELECT ON raw.source_documents TO gurine_analysis_worker, gurine_control_api, gurine_ingest_worker, gurine_document_extractor;
CREATE OR REPLACE FUNCTION raw.insert_source_document_revision(
  p_source_id text, p_external_id text, p_external_version text, p_canonical_url text,
  p_source_fetch_id uuid, p_retrieved_at timestamptz, p_source_published_at timestamptz,
  p_content_type text, p_content_sha256 char(64), p_content_size_bytes bigint, p_object_key text,
  p_status core.source_document_status, p_parser_name text, p_parser_version text,
  p_schema_version text, p_prompt_injection_flags jsonb, p_quarantine_reason text, p_metadata jsonb
) RETURNS raw.source_documents LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, raw, core, extensions, pg_temp AS $$
DECLARE v_root uuid; v_revision bigint; v_existing raw.source_documents%ROWTYPE; v_id uuid := gen_random_uuid();
BEGIN
  IF NULLIF(btrim(p_source_id),'') IS NULL OR NULLIF(btrim(p_external_id),'') IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' OR p_content_size_bytes < 0 THEN RAISE EXCEPTION 'invalid_source_document_revision' USING ERRCODE='22023'; END IF;
  -- PostgreSQL text cannot contain NUL; use a control separator that remains
  -- unambiguous for the advisory-lock key while keeping source/id domains
  -- collision-safe.
  PERFORM pg_advisory_xact_lock(('x' || substr(encode(extensions.digest(convert_to(p_source_id || chr(31) || p_external_id,'UTF8'),'sha256'),'hex'),1,16))::bit(64)::bigint);
  SELECT * INTO v_existing FROM raw.source_documents WHERE source_id=p_source_id AND external_id=p_external_id AND content_sha256=p_content_sha256 ORDER BY asset_revision LIMIT 1 FOR UPDATE;
  IF FOUND THEN RETURN v_existing; END IF;
  -- The advisory lock above serializes revisions for this source/external id;
  -- PostgreSQL disallows FOR UPDATE on this grouped aggregate, so the lock is
  -- both sufficient and the portable form here.
  SELECT asset_id, max(asset_revision) INTO v_root, v_revision FROM raw.source_documents WHERE source_id=p_source_id AND external_id=p_external_id GROUP BY asset_id ORDER BY max(asset_revision) DESC LIMIT 1;
  IF v_root IS NULL THEN v_root := v_id; v_revision := 1; ELSE v_revision := v_revision + 1; END IF;
  INSERT INTO raw.source_documents(id,source_id,source_fetch_id,external_id,external_version,canonical_url,retrieved_at,source_published_at,content_type,content_sha256,content_size_bytes,object_key,status,parser_name,parser_version,schema_version,prompt_injection_flags,quarantine_reason,metadata,asset_id,asset_revision)
  VALUES(v_id,p_source_id,p_source_fetch_id,p_external_id,p_external_version,p_canonical_url,p_retrieved_at,p_source_published_at,p_content_type,p_content_sha256,p_content_size_bytes,p_object_key,p_status,p_parser_name,p_parser_version,p_schema_version,COALESCE(p_prompt_injection_flags,'[]'::jsonb),p_quarantine_reason,COALESCE(p_metadata,'{}'::jsonb),v_root,v_revision)
  RETURNING * INTO v_existing;
  RETURN v_existing;
END $$;
ALTER FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) TO gurine_ingest_worker;
CREATE TABLE core.normalization_runs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  source_document_id uuid NOT NULL,
  parser_run_id uuid NOT NULL,
  parsed_record_id uuid NOT NULL,
  parser_version text NOT NULL,
  input_payload_sha256 char(64) NOT NULL,
  normalization_id text NOT NULL,
  normalization_version text NOT NULL,
  normalization_contract_sha256 char(64) NOT NULL,
  implementation_sha256 char(64) NOT NULL,
  producer_generation bigint NOT NULL,
  state text NOT NULL DEFAULT 'RUNNING',
  output_object_type text,
  output_object_id uuid,
  output_object_version bigint,
  output_payload_sha256 char(64),
  field_provenance_count bigint NOT NULL DEFAULT 0,
  field_provenance_set_sha256 char(64),
  error_code text,
  error_sha256 char(64),
  terminal_receipt_sha256 char(64),
  terminal_audit_event_id uuid,
  job_id uuid NOT NULL,
  job_fencing_token bigint NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT normalization_runs_pk PRIMARY KEY (id)
);
ALTER TABLE core.normalization_runs OWNER TO gurine_migrator;
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_generation_uk UNIQUE (parsed_record_id, normalization_id, normalization_version, producer_generation);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_output_binding_uk UNIQUE (id, state, output_object_type, output_object_id, output_object_version, output_payload_sha256, normalization_version, normalization_contract_sha256);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_source_binding_uk UNIQUE (id, source_document_id);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_procurement_output_uk UNIQUE (id, source_document_id, output_object_id, output_object_version, output_payload_sha256);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_generation_ck CHECK (producer_generation > 0);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_version_ck CHECK (version > 0 AND job_fencing_token > 0);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_state_ck CHECK (state IN ('RUNNING','SUCCEEDED','FAILED'));
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_output_type_ck CHECK (output_object_type IS NULL OR output_object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION','PROCUREMENT_NOTICE','PROCUREMENT_AWARD','PROCUREMENT_BIDDER_PARTICIPATION','PROCUREMENT_CONTRACT','PROCUREMENT_CONTRACT_AMENDMENT','PROCUREMENT_CONTRACT_LINE_ITEM','SUPPLIER_IDENTITY_CANDIDATE'));
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_terminal_shape_ck CHECK ((state='RUNNING' AND version=1 AND completed_at IS NULL AND output_object_type IS NULL AND output_object_id IS NULL AND output_object_version IS NULL AND output_payload_sha256 IS NULL AND field_provenance_count=0 AND field_provenance_set_sha256 IS NULL AND error_code IS NULL AND error_sha256 IS NULL AND terminal_receipt_sha256 IS NULL AND terminal_audit_event_id IS NULL) OR (state='SUCCEEDED' AND version=2 AND completed_at IS NOT NULL AND output_object_type IS NOT NULL AND output_object_id IS NOT NULL AND output_object_version IS NOT NULL AND output_object_version > 0 AND output_payload_sha256 IS NOT NULL AND field_provenance_count > 0 AND field_provenance_set_sha256 IS NOT NULL AND error_code IS NULL AND error_sha256 IS NULL AND terminal_receipt_sha256 IS NOT NULL AND terminal_audit_event_id IS NOT NULL) OR (state='FAILED' AND version=2 AND completed_at IS NOT NULL AND output_object_type IS NULL AND output_object_id IS NULL AND output_object_version IS NULL AND output_payload_sha256 IS NULL AND field_provenance_count=0 AND field_provenance_set_sha256 IS NULL AND error_code IS NOT NULL AND error_sha256 IS NOT NULL AND terminal_receipt_sha256 IS NOT NULL AND terminal_audit_event_id IS NOT NULL));
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_time_ck CHECK (completed_at IS NULL OR completed_at >= started_at);
ALTER TABLE core.normalization_runs ADD CONSTRAINT normalization_runs_nonempty_ck CHECK (length(btrim(normalization_id)) > 0 AND length(btrim(normalization_version)) > 0);
REVOKE ALL ON core.normalization_runs FROM PUBLIC;
REVOKE ALL ON core.normalization_runs FROM gurine_workflow_worker;
REVOKE ALL ON core.normalization_runs FROM gurine_control_api;
REVOKE ALL ON core.normalization_runs FROM gurine_analysis_worker;
REVOKE ALL ON core.normalization_runs FROM gurine_public_projector;
REVOKE ALL ON core.normalization_runs FROM gurine_notification_worker;
REVOKE ALL ON core.normalization_runs FROM gurine_submission_api;
REVOKE ALL ON core.normalization_runs FROM gurine_auditor;
GRANT SELECT, INSERT ON core.normalization_runs TO gurine_ingest_worker;
GRANT SELECT ON core.normalization_runs TO gurine_analysis_worker;
GRANT SELECT ON core.normalization_runs TO gurine_control_api;
CREATE TABLE raw.evidence_segments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  parser_run_id uuid NOT NULL,
  parser_name text NOT NULL,
  parser_version text NOT NULL,
  segment_ordinal integer NOT NULL,
  locator_kind text NOT NULL,
  locator_value text NOT NULL,
  locator_digest char(64) NOT NULL,
  raw_value_sha256 char(64) NOT NULL,
  selected_content_sha256 char(64) NOT NULL,
  selected_content_object_key text NOT NULL,
  selected_content_locator text NOT NULL,
  selected_content_media_type text NOT NULL,
  transformation_version text,
  confidence numeric(7,6),
  classification text NOT NULL,
  source_authority text NOT NULL,
  retrieved_at timestamptz NOT NULL,
  segment_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT evidence_segments_pk PRIMARY KEY (id)
);
ALTER TABLE raw.evidence_segments OWNER TO gurine_migrator;
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_parser_ordinal_uk UNIQUE (parser_run_id, segment_ordinal);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_locator_uk UNIQUE (source_asset_id, source_asset_revision, parser_run_id, locator_digest, transformation_version);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_editorial_binding_uk UNIQUE (id, source_document_id, source_content_sha256);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_citation_binding_uk UNIQUE (id, locator_digest, selected_content_sha256);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_content_binding_uk UNIQUE (id, selected_content_sha256);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_lineage_binding_uk UNIQUE (id, source_document_id, locator_digest);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_source_use_binding_uk UNIQUE (id, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, selected_content_sha256, locator_digest);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_revision_ordinal_ck CHECK (source_asset_revision > 0 AND segment_ordinal >= 0);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_locator_kind_ck CHECK (locator_kind IN ('PAGE_BBOX','XLSX_CELL','CSV_ROW_COLUMN','XML_XPATH','DOCX_PARAGRAPH','HWPX_XPATH','JSON_POINTER','HTML_CSS_SELECTOR','API_FIELD','TEXT_RANGE','IMAGE_BBOX','AUDIO_TIME_RANGE','VIDEO_TIME_RANGE','VIDEO_REGION_TIME'));
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_confidence_ck CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1);
ALTER TABLE raw.evidence_segments ADD CONSTRAINT evidence_segments_nonempty_ck CHECK (length(btrim(locator_value)) > 0 AND length(btrim(parser_name)) > 0 AND length(btrim(parser_version)) > 0 AND length(btrim(selected_content_object_key)) > 0 AND length(btrim(selected_content_locator)) > 0 AND length(btrim(selected_content_media_type)) > 0 AND length(btrim(source_authority)) > 0);
REVOKE ALL ON raw.evidence_segments FROM PUBLIC;
REVOKE ALL ON raw.evidence_segments FROM gurine_workflow_worker;
REVOKE ALL ON raw.evidence_segments FROM gurine_control_api;
REVOKE ALL ON raw.evidence_segments FROM gurine_analysis_worker;
REVOKE ALL ON raw.evidence_segments FROM gurine_public_projector;
REVOKE ALL ON raw.evidence_segments FROM gurine_notification_worker;
REVOKE ALL ON raw.evidence_segments FROM gurine_submission_api;
REVOKE ALL ON raw.evidence_segments FROM gurine_auditor;
GRANT SELECT, INSERT ON raw.evidence_segments TO gurine_ingest_worker;
GRANT SELECT ON raw.evidence_segments TO gurine_analysis_worker;
GRANT SELECT ON raw.evidence_segments TO gurine_control_api;
GRANT SELECT ON raw.evidence_segments TO gurine_workflow_worker;
CREATE TRIGGER raw_evidence_segments_immutable_mutation_guard BEFORE UPDATE OR DELETE ON raw.evidence_segments FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.dataset_snapshots (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  contract_version smallint NOT NULL DEFAULT 1,
  snapshot_kind text NOT NULL,
  producer_component text NOT NULL,
  producer_job_id uuid NOT NULL,
  producer_key text NOT NULL,
  producer_digest char(64) NOT NULL,
  producer_generation bigint NOT NULL,
  projection_watermark bigint,
  generation_mode text,
  prior_snapshot_id uuid,
  prior_snapshot_sha256 char(64),
  state text NOT NULL DEFAULT 'BUILDING',
  schema_version text NOT NULL,
  selection_spec jsonb NOT NULL,
  selection_canonical bytea NOT NULL,
  selection_sha256 char(64) NOT NULL,
  source_watermarks jsonb NOT NULL,
  source_watermarks_canonical bytea NOT NULL,
  source_watermark_sha256 char(64) NOT NULL,
  normalization_versions jsonb NOT NULL,
  normalization_versions_canonical bytea NOT NULL,
  normalization_set_sha256 char(64) NOT NULL,
  member_count bigint NOT NULL DEFAULT 0,
  member_set_sha256 char(64),
  snapshot_manifest jsonb,
  snapshot_manifest_canonical bytea,
  snapshot_sha256 char(64),
  build_request_sha256 char(64) NOT NULL,
  build_started_audit_event_id uuid NOT NULL,
  terminal_receipt_sha256 char(64),
  terminal_audit_event_id uuid,
  error_code text,
  error_sha256 char(64),
  version bigint NOT NULL DEFAULT 1,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ready_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT dataset_snapshots_pk PRIMARY KEY (id)
);
ALTER TABLE core.dataset_snapshots OWNER TO gurine_migrator;
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_generation_uk UNIQUE (snapshot_kind, producer_key, producer_generation);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_producer_generation_uk UNIQUE (snapshot_kind, producer_digest, producer_generation);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_child_binding_uk UNIQUE (id, snapshot_kind, producer_generation, projection_watermark, contract_version);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_member_binding_uk UNIQUE (id, snapshot_kind, producer_generation, contract_version);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_hash_binding_uk UNIQUE (id, snapshot_sha256);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_paid_binding_uk UNIQUE (id, version, snapshot_sha256);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_prior_binding_uk UNIQUE (id, snapshot_kind, snapshot_sha256);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_contract_ck CHECK (contract_version = 1);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_kind_ck CHECK (snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET','PUBLIC_SEARCH_PROJECTION','INTERNAL_SEARCH_PROJECTION'));
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_producer_ck CHECK ((snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET') AND producer_component='snapshot-producer') OR (snapshot_kind='PUBLIC_SEARCH_PROJECTION' AND producer_component='public-search-projector') OR (snapshot_kind='INTERNAL_SEARCH_PROJECTION' AND producer_component='internal-search-projector'));
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_generation_ck CHECK (producer_generation > 0 AND member_count >= 0 AND version > 0);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_projection_shape_ck CHECK ((snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET') AND projection_watermark IS NULL AND generation_mode IS NULL AND prior_snapshot_id IS NULL AND prior_snapshot_sha256 IS NULL) OR (snapshot_kind IN ('PUBLIC_SEARCH_PROJECTION','INTERNAL_SEARCH_PROJECTION') AND projection_watermark IS NOT NULL AND projection_watermark >= 0 AND generation_mode IS NOT NULL AND generation_mode IN ('FULL','DELTA') AND ((generation_mode='FULL' AND prior_snapshot_id IS NULL AND prior_snapshot_sha256 IS NULL) OR (generation_mode='DELTA' AND prior_snapshot_id IS NOT NULL AND prior_snapshot_sha256 IS NOT NULL))));
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_state_ck CHECK (state IN ('BUILDING','READY','FAILED'));
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_nonempty_ck CHECK (length(btrim(producer_key)) > 0 AND length(btrim(schema_version)) > 0);
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_canonical_json_ck CHECK (convert_from(selection_canonical,'UTF8')::jsonb=selection_spec AND convert_from(source_watermarks_canonical,'UTF8')::jsonb=source_watermarks AND convert_from(normalization_versions_canonical,'UTF8')::jsonb=normalization_versions AND (snapshot_manifest_canonical IS NULL OR convert_from(snapshot_manifest_canonical,'UTF8')::jsonb=snapshot_manifest));
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_terminal_shape_ck CHECK ((state='BUILDING' AND version=1 AND ready_at IS NULL AND failed_at IS NULL AND snapshot_manifest IS NULL AND snapshot_manifest_canonical IS NULL AND snapshot_sha256 IS NULL AND terminal_receipt_sha256 IS NULL AND terminal_audit_event_id IS NULL AND error_code IS NULL AND error_sha256 IS NULL) OR (state='READY' AND version=2 AND ready_at IS NOT NULL AND failed_at IS NULL AND member_set_sha256 IS NOT NULL AND snapshot_manifest IS NOT NULL AND snapshot_manifest_canonical IS NOT NULL AND snapshot_sha256 IS NOT NULL AND terminal_receipt_sha256 IS NOT NULL AND terminal_audit_event_id IS NOT NULL AND error_code IS NULL AND error_sha256 IS NULL) OR (state='FAILED' AND version=2 AND failed_at IS NOT NULL AND ready_at IS NULL AND member_count=0 AND member_set_sha256 IS NULL AND snapshot_manifest IS NULL AND snapshot_manifest_canonical IS NULL AND snapshot_sha256 IS NULL AND terminal_receipt_sha256 IS NOT NULL AND terminal_audit_event_id IS NOT NULL AND error_code IS NOT NULL AND error_sha256 IS NOT NULL));
REVOKE ALL ON core.dataset_snapshots FROM PUBLIC;
REVOKE ALL ON core.dataset_snapshots FROM gurine_workflow_worker;
REVOKE ALL ON core.dataset_snapshots FROM gurine_control_api;
REVOKE ALL ON core.dataset_snapshots FROM gurine_analysis_worker;
REVOKE ALL ON core.dataset_snapshots FROM gurine_public_projector;
REVOKE ALL ON core.dataset_snapshots FROM gurine_notification_worker;
REVOKE ALL ON core.dataset_snapshots FROM gurine_submission_api;
REVOKE ALL ON core.dataset_snapshots FROM gurine_auditor;
GRANT SELECT, INSERT ON core.dataset_snapshots TO gurine_analysis_worker;
GRANT SELECT ON core.dataset_snapshots TO gurine_control_api;
CREATE TABLE core.dataset_snapshot_members (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  dataset_snapshot_id uuid NOT NULL,
  snapshot_kind text NOT NULL,
  producer_generation bigint NOT NULL,
  snapshot_contract_version smallint NOT NULL,
  member_ordinal bigint NOT NULL,
  object_type text NOT NULL,
  object_id uuid NOT NULL,
  object_version bigint NOT NULL,
  object_schema_version text NOT NULL,
  object_content_sha256 char(64) NOT NULL,
  canonical_payload jsonb NOT NULL,
  canonical_payload_bytes bytea NOT NULL,
  payload_sha256 char(64) NOT NULL,
  normalization_run_id uuid,
  normalization_version text,
  normalization_sha256 char(64),
  evidence_segment_id uuid,
  response_id uuid,
  source_count integer NOT NULL,
  source_set_sha256 char(64) NOT NULL,
  member_binding_canonical bytea NOT NULL,
  member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT dataset_snapshot_members_pk PRIMARY KEY (id)
);
ALTER TABLE core.dataset_snapshot_members OWNER TO gurine_migrator;
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_ordinal_uk UNIQUE (dataset_snapshot_id, member_ordinal);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_object_uk UNIQUE (dataset_snapshot_id, object_type, object_id, object_version);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_digest_uk UNIQUE (dataset_snapshot_id, member_digest);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_citation_binding_uk UNIQUE (id, dataset_snapshot_id, member_digest);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_source_binding_uk UNIQUE (id, dataset_snapshot_id, member_ordinal, member_digest);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_source_use_binding_uk UNIQUE (id, dataset_snapshot_id, member_digest, object_type, object_id, object_version, object_content_sha256);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_kind_ck CHECK (snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET'));
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_positive_ck CHECK (member_ordinal >= 0 AND object_version > 0 AND producer_generation > 0 AND source_count > 0);
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_object_type_ck CHECK (object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION','EVIDENCE_SEGMENT','RESPONSE'));
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_source_shape_ck CHECK ((object_type='EVIDENCE_SEGMENT' AND evidence_segment_id IS NOT NULL AND evidence_segment_id=object_id AND response_id IS NULL AND normalization_run_id IS NULL AND normalization_version IS NULL AND normalization_sha256 IS NULL) OR (object_type='RESPONSE' AND response_id IS NOT NULL AND response_id=object_id AND evidence_segment_id IS NULL AND normalization_run_id IS NULL AND normalization_version IS NULL AND normalization_sha256 IS NULL) OR (object_type NOT IN ('EVIDENCE_SEGMENT','RESPONSE') AND evidence_segment_id IS NULL AND response_id IS NULL AND normalization_run_id IS NOT NULL AND normalization_version IS NOT NULL AND normalization_sha256 IS NOT NULL));
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_canonical_ck CHECK (convert_from(canonical_payload_bytes,'UTF8')::jsonb=canonical_payload);
REVOKE ALL ON core.dataset_snapshot_members FROM PUBLIC;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_workflow_worker;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_control_api;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_analysis_worker;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_public_projector;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_notification_worker;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_submission_api;
REVOKE ALL ON core.dataset_snapshot_members FROM gurine_auditor;
GRANT SELECT, INSERT ON core.dataset_snapshot_members TO gurine_analysis_worker;
GRANT SELECT ON core.dataset_snapshot_members TO gurine_control_api;
CREATE TRIGGER core_dataset_snapshot_members_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.dataset_snapshot_members FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.dataset_snapshot_member_sources (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  dataset_snapshot_id uuid NOT NULL,
  snapshot_member_id uuid NOT NULL,
  member_ordinal bigint NOT NULL,
  snapshot_member_digest char(64) NOT NULL,
  source_ordinal integer NOT NULL,
  lineage_kind text NOT NULL,
  source_kind text NOT NULL,
  source_document_id uuid,
  source_asset_id uuid,
  source_asset_revision bigint,
  source_content_sha256 char(64),
  response_id uuid,
  response_version bigint,
  response_content_sha256 char(64),
  parser_run_id uuid,
  parsed_record_id uuid,
  normalization_run_id uuid,
  field_provenance_id uuid,
  evidence_segment_id uuid,
  locator_digest char(64),
  source_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT dataset_snapshot_member_sources_pk PRIMARY KEY (id)
);
ALTER TABLE core.dataset_snapshot_member_sources OWNER TO gurine_migrator;
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_ordinal_uk UNIQUE (dataset_snapshot_id, member_ordinal, source_ordinal);
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_digest_uk UNIQUE (snapshot_member_id, source_digest);
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_lineage_uk UNIQUE (snapshot_member_id, source_document_id, response_id, normalization_run_id, parser_run_id, parsed_record_id, field_provenance_id);
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_document_use_uk UNIQUE (id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, source_digest);
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_response_use_uk UNIQUE (id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, response_id, response_version, response_content_sha256, source_digest);
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_positive_ck CHECK (source_ordinal >= 0 AND (source_asset_revision IS NULL OR source_asset_revision > 0));
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_kind_ck CHECK (source_kind IN ('SOURCE_DOCUMENT','RESPONSE') AND lineage_kind IN ('DIRECT_SOURCE','PARSED_RECORD','NORMALIZED_FIELD','EVIDENCE_SEGMENT','RESPONSE'));
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_target_ck CHECK ((source_kind='SOURCE_DOCUMENT' AND source_document_id IS NOT NULL AND source_asset_id IS NOT NULL AND source_asset_revision IS NOT NULL AND source_content_sha256 IS NOT NULL AND response_id IS NULL AND response_version IS NULL AND response_content_sha256 IS NULL) OR (source_kind='RESPONSE' AND response_id IS NOT NULL AND response_version IS NOT NULL AND response_version > 0 AND response_content_sha256 IS NOT NULL AND source_document_id IS NULL AND source_asset_id IS NULL AND source_asset_revision IS NULL AND source_content_sha256 IS NULL));
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_shape_ck CHECK ((lineage_kind='DIRECT_SOURCE' AND source_kind='SOURCE_DOCUMENT' AND parser_run_id IS NULL AND parsed_record_id IS NULL AND normalization_run_id IS NULL AND field_provenance_id IS NULL AND evidence_segment_id IS NULL AND locator_digest IS NULL) OR (lineage_kind='PARSED_RECORD' AND source_kind='SOURCE_DOCUMENT' AND parser_run_id IS NOT NULL AND parsed_record_id IS NOT NULL AND normalization_run_id IS NULL AND field_provenance_id IS NULL AND evidence_segment_id IS NULL) OR (lineage_kind='NORMALIZED_FIELD' AND source_kind='SOURCE_DOCUMENT' AND parser_run_id IS NOT NULL AND parsed_record_id IS NOT NULL AND normalization_run_id IS NOT NULL AND field_provenance_id IS NOT NULL AND evidence_segment_id IS NULL) OR (lineage_kind='EVIDENCE_SEGMENT' AND source_kind='SOURCE_DOCUMENT' AND parser_run_id IS NOT NULL AND parsed_record_id IS NULL AND normalization_run_id IS NULL AND field_provenance_id IS NULL AND evidence_segment_id IS NOT NULL AND locator_digest IS NOT NULL) OR (lineage_kind='RESPONSE' AND source_kind='RESPONSE' AND parser_run_id IS NULL AND parsed_record_id IS NULL AND normalization_run_id IS NULL AND field_provenance_id IS NULL AND evidence_segment_id IS NULL AND locator_digest IS NULL));
REVOKE ALL ON core.dataset_snapshot_member_sources FROM PUBLIC;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_workflow_worker;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_control_api;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_analysis_worker;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_public_projector;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_notification_worker;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_submission_api;
REVOKE ALL ON core.dataset_snapshot_member_sources FROM gurine_auditor;
GRANT SELECT, INSERT ON core.dataset_snapshot_member_sources TO gurine_analysis_worker;
GRANT SELECT ON core.dataset_snapshot_member_sources TO gurine_control_api;
CREATE TRIGGER core_dataset_snapshot_member_sources_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.dataset_snapshot_member_sources FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_provider_turns (
  provider_turn_id uuid NOT NULL DEFAULT gen_random_uuid(),
  agent_run_id uuid NOT NULL,
  input_snapshot_sha256 char(64) NOT NULL,
  turn_sequence integer NOT NULL,
  attempt_sequence integer NOT NULL,
  prior_transcript_sha256 char(64) NOT NULL,
  provider_config_id uuid,
  provider_mode text NOT NULL,
  provider_candidate_id text NOT NULL,
  model_id text NOT NULL,
  model_configuration_sha256 char(64) NOT NULL,
  routing_policy_version text NOT NULL,
  routing_decision_sha256 char(64) NOT NULL,
  prompt_id text NOT NULL,
  prompt_version text NOT NULL,
  prompt_sha256 char(64) NOT NULL,
  output_schema_id text NOT NULL,
  output_schema_version text NOT NULL,
  output_schema_sha256 char(64) NOT NULL,
  classification text NOT NULL,
  model_use_rights_sha256 char(64) NOT NULL,
  budget_reservation_key_sha256 char(64) NOT NULL,
  dispatch_key_sha256 char(64) NOT NULL,
  request_sha256 char(64) NOT NULL,
  request_redacted jsonb NOT NULL,
  request_canonical bytea NOT NULL,
  status text NOT NULL DEFAULT 'DISPATCHED',
  envelope_kind text,
  envelope_sha256 char(64),
  envelope_payload_sha256 char(64),
  envelope_canonical bytea,
  response_redacted jsonb,
  response_redacted_canonical bytea,
  call_id text,
  tool_id text,
  provider_receipt_id uuid,
  provider_receipt jsonb,
  provider_receipt_canonical bytea,
  provider_receipt_sha256 char(64),
  provider_turn_canonical bytea,
  provider_turn_sha256 char(64),
  turn_transcript_sha256 char(64),
  input_units bigint,
  output_units bigint,
  latency_ms bigint,
  cost_event_id uuid,
  provider_request_id_hash char(64),
  error_code text,
  error_sha256 char(64),
  version bigint NOT NULL DEFAULT 1,
  dispatched_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_provider_turns_pk PRIMARY KEY (provider_turn_id)
);
ALTER TABLE ops.agent_provider_turns OWNER TO gurine_migrator;
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_attempt_uk UNIQUE (agent_run_id, turn_sequence, attempt_sequence);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_run_binding_uk UNIQUE (agent_run_id, provider_turn_id);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_dispatch_uk UNIQUE (agent_run_id, dispatch_key_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_receipt_uk UNIQUE (provider_receipt_id);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_receipt_binding_uk UNIQUE (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_digest_uk UNIQUE (agent_run_id, provider_turn_id, provider_turn_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_tool_binding_uk UNIQUE (agent_run_id, provider_turn_id, status, envelope_kind, call_id, tool_id, envelope_payload_sha256, prior_transcript_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_output_binding_uk UNIQUE (agent_run_id, provider_turn_id, status, envelope_kind, envelope_payload_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_sequence_version_ck CHECK (turn_sequence > 0 AND attempt_sequence > 0 AND version > 0);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_mode_ck CHECK (provider_mode IN ('EXTERNAL_APPROVED','LOCAL_APPROVED','DETERMINISTIC_DOUBLE'));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_status_ck CHECK (status IN ('DISPATCHED','COMPLETED','PROVIDER_FAILED','RATE_LIMITED','TIMED_OUT','CANCELLED','OUTCOME_UNKNOWN'));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_envelope_ck CHECK (envelope_kind IS NULL OR envelope_kind IN ('FINAL_OUTPUT','TOOL_CALL'));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_provider_shape_ck CHECK ((provider_mode='EXTERNAL_APPROVED' AND provider_config_id IS NOT NULL AND classification IN ('PUBLIC','INTERNAL')) OR (provider_mode='LOCAL_APPROVED') OR (provider_mode='DETERMINISTIC_DOUBLE' AND provider_config_id IS NULL));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_request_canonical_ck CHECK (convert_from(request_canonical,'UTF8')::jsonb=request_redacted AND encode(extensions.digest(request_canonical,'sha256'),'hex')=request_sha256);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_terminal_shape_ck CHECK ((status='DISPATCHED' AND completed_at IS NULL AND envelope_kind IS NULL AND envelope_canonical IS NULL AND response_redacted IS NULL AND response_redacted_canonical IS NULL AND provider_receipt_id IS NULL AND provider_receipt IS NULL AND provider_receipt_canonical IS NULL AND provider_receipt_sha256 IS NULL AND provider_turn_canonical IS NULL AND provider_turn_sha256 IS NULL AND turn_transcript_sha256 IS NULL AND error_code IS NULL AND error_sha256 IS NULL) OR (status='COMPLETED' AND completed_at IS NOT NULL AND envelope_kind IS NOT NULL AND envelope_sha256 IS NOT NULL AND envelope_payload_sha256 IS NOT NULL AND envelope_canonical IS NOT NULL AND response_redacted IS NOT NULL AND response_redacted_canonical IS NOT NULL AND provider_receipt_id IS NOT NULL AND provider_receipt IS NOT NULL AND provider_receipt_canonical IS NOT NULL AND provider_receipt_sha256 IS NOT NULL AND provider_turn_canonical IS NOT NULL AND provider_turn_sha256 IS NOT NULL AND turn_transcript_sha256 IS NOT NULL AND latency_ms IS NOT NULL AND latency_ms >= 0 AND error_code IS NULL AND error_sha256 IS NULL) OR (status IN ('PROVIDER_FAILED','RATE_LIMITED','TIMED_OUT','CANCELLED','OUTCOME_UNKNOWN') AND completed_at IS NOT NULL AND envelope_kind IS NULL AND envelope_sha256 IS NULL AND envelope_payload_sha256 IS NULL AND envelope_canonical IS NULL AND response_redacted IS NULL AND response_redacted_canonical IS NULL AND provider_receipt_id IS NOT NULL AND provider_receipt IS NOT NULL AND provider_receipt_canonical IS NOT NULL AND provider_receipt_sha256 IS NOT NULL AND provider_turn_canonical IS NOT NULL AND provider_turn_sha256 IS NOT NULL AND turn_transcript_sha256 IS NULL AND error_code IS NOT NULL AND error_sha256 IS NOT NULL AND latency_ms IS NOT NULL AND latency_ms >= 0));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_terminal_canonical_ck CHECK (provider_receipt_canonical IS NULL OR (convert_from(provider_receipt_canonical,'UTF8')::jsonb=provider_receipt AND encode(extensions.digest(provider_receipt_canonical,'sha256'),'hex')=provider_receipt_sha256 AND encode(extensions.digest(provider_turn_canonical,'sha256'),'hex')=provider_turn_sha256));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_response_canonical_ck CHECK (response_redacted_canonical IS NULL OR convert_from(response_redacted_canonical,'UTF8')::jsonb=response_redacted);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_tool_shape_ck CHECK ((envelope_kind='TOOL_CALL' AND call_id IS NOT NULL AND tool_id IS NOT NULL) OR (envelope_kind='FINAL_OUTPUT' AND call_id IS NULL AND tool_id IS NULL) OR envelope_kind IS NULL);
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_error_code_ck CHECK (error_code IS NULL OR error_code IN ('PROVIDER_REJECTED','PROVIDER_RATE_LIMITED','PROVIDER_TIMEOUT','PROVIDER_CANCELLED','PROVIDER_OUTCOME_UNKNOWN','PROVIDER_RECEIPT_INVALID','PROVIDER_RESPONSE_INVALID'));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_usage_ck CHECK ((input_units IS NULL OR input_units >= 0) AND (output_units IS NULL OR output_units >= 0) AND (latency_ms IS NULL OR latency_ms >= 0));
ALTER TABLE ops.agent_provider_turns ADD CONSTRAINT agent_provider_turns_time_ck CHECK (completed_at IS NULL OR completed_at >= dispatched_at);
REVOKE ALL ON ops.agent_provider_turns FROM PUBLIC;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_control_api;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_public_projector;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_submission_api;
REVOKE ALL ON ops.agent_provider_turns FROM gurine_auditor;
GRANT SELECT, INSERT ON ops.agent_provider_turns TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_provider_turns TO gurine_control_api;
CREATE TABLE ops.agent_tool_calls (
  tool_call_id uuid NOT NULL DEFAULT gen_random_uuid(),
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid NOT NULL,
  call_id text NOT NULL,
  input_snapshot_sha256 char(64) NOT NULL,
  prior_transcript_sha256 char(64) NOT NULL,
  tool_id text NOT NULL,
  tool_catalog_version text NOT NULL,
  tool_catalog_sha256 char(64) NOT NULL,
  request_schema_id text NOT NULL,
  request_schema_version text NOT NULL,
  request_schema_sha256 char(64) NOT NULL,
  response_schema_id text NOT NULL,
  response_schema_version text NOT NULL,
  response_schema_sha256 char(64) NOT NULL,
  timeout_ms integer NOT NULL,
  max_results integer NOT NULL,
  request_sha256 char(64) NOT NULL,
  request_redacted jsonb NOT NULL,
  request_canonical bytea NOT NULL,
  allowlist_decision_sha256 char(64) NOT NULL,
  scope_decision_sha256 char(64) NOT NULL,
  rights_decision_sha256 char(64) NOT NULL,
  classification text NOT NULL,
  budget_reservation_key_sha256 char(64),
  status text NOT NULL DEFAULT 'CLAIMED',
  result_kind text,
  result_sha256 char(64),
  result_redacted jsonb,
  result_canonical bytea,
  response_validation_sha256 char(64),
  result_transcript_sha256 char(64),
  source_use_count integer NOT NULL DEFAULT 0,
  source_use_set_sha256 char(64) NOT NULL DEFAULT '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  latency_ms bigint,
  cost_event_id uuid,
  terminal_code text,
  terminal_sha256 char(64),
  claim_generation bigint NOT NULL DEFAULT 1,
  lease_token_sha256 char(64) NOT NULL,
  lease_expires_at timestamptz NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  terminal_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_tool_calls_pk PRIMARY KEY (tool_call_id)
);
ALTER TABLE ops.agent_tool_calls OWNER TO gurine_migrator;
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_idempotency_uk UNIQUE (agent_run_id, call_id);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_run_binding_uk UNIQUE (agent_run_id, tool_call_id);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_artifact_binding_uk UNIQUE (agent_run_id, call_id, request_sha256, result_sha256);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_source_use_binding_uk UNIQUE (agent_run_id, tool_call_id, source_use_count, source_use_set_sha256);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_id_ck CHECK (call_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_tool_ck CHECK (tool_id IN ('claim.language_check','contract.find_comparables','entity.lookup','evidence.read','evidence.search','response.read','rule.reproduce','source.fetch','source.locator_verify'));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_bounds_ck CHECK (timeout_ms BETWEEN 1 AND 120000 AND max_results BETWEEN 1 AND 50 AND claim_generation > 0 AND version > 0 AND source_use_count >= 0);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_status_ck CHECK (status IN ('CLAIMED','SUCCEEDED','DENIED','TIMED_OUT','FAILED','OUTCOME_UNKNOWN'));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_result_kind_ck CHECK (result_kind IS NULL OR result_kind IN ('TOOL_RESULT','DISPATCH_DENIAL','TOOL_ERROR'));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_schema_binding_ck CHECK (ops.agent_tool_schema_contract_is_valid(tool_id,request_schema_sha256,response_schema_sha256) AND ops.agent_tool_payload_is_valid(tool_id,request_redacted,result_redacted));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_request_canonical_ck CHECK (convert_from(request_canonical,'UTF8')::jsonb=request_redacted AND encode(extensions.digest(request_canonical,'sha256'),'hex')=request_sha256);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_result_canonical_ck CHECK (result_canonical IS NULL OR (result_redacted IS NOT NULL AND convert_from(result_canonical,'UTF8')::jsonb=result_redacted AND encode(extensions.digest(result_canonical,'sha256'),'hex')=result_sha256));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_terminal_shape_ck CHECK ((status='CLAIMED' AND terminal_at IS NULL AND result_kind IS NULL AND result_sha256 IS NULL AND result_redacted IS NULL AND result_canonical IS NULL AND response_validation_sha256 IS NULL AND result_transcript_sha256 IS NULL AND terminal_code IS NULL AND terminal_sha256 IS NULL AND source_use_count=0 AND source_use_set_sha256='4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945') OR (status='SUCCEEDED' AND terminal_at IS NOT NULL AND result_kind='TOOL_RESULT' AND result_sha256 IS NOT NULL AND result_redacted IS NOT NULL AND result_canonical IS NOT NULL AND response_validation_sha256 IS NOT NULL AND result_transcript_sha256 IS NOT NULL AND latency_ms IS NOT NULL AND latency_ms >= 0 AND terminal_code IS NULL AND terminal_sha256 IS NULL) OR (status IN ('DENIED','TIMED_OUT','FAILED','OUTCOME_UNKNOWN') AND terminal_at IS NOT NULL AND result_kind IN ('DISPATCH_DENIAL','TOOL_ERROR') AND result_sha256 IS NOT NULL AND result_redacted IS NULL AND result_canonical IS NULL AND response_validation_sha256 IS NULL AND result_transcript_sha256 IS NOT NULL AND latency_ms IS NOT NULL AND latency_ms >= 0 AND terminal_code IS NOT NULL AND terminal_sha256 IS NOT NULL));
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_budget_shape_ck CHECK (status<>'DENIED' OR budget_reservation_key_sha256 IS NULL);
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_time_ck CHECK (lease_expires_at > started_at AND (terminal_at IS NULL OR terminal_at >= started_at));
REVOKE ALL ON ops.agent_tool_calls FROM PUBLIC;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_control_api;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_public_projector;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_submission_api;
REVOKE ALL ON ops.agent_tool_calls FROM gurine_auditor;
GRANT SELECT, INSERT ON ops.agent_tool_calls TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_tool_calls TO gurine_control_api;
CREATE TABLE raw.research_artifacts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL,
  asset_revision bigint NOT NULL,
  source_fetch_id uuid NOT NULL,
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid NOT NULL,
  tool_call_id uuid NOT NULL,
  call_id text NOT NULL,
  artifact_ordinal integer NOT NULL,
  input_snapshot_sha256 char(64) NOT NULL,
  request_kind text NOT NULL,
  request_sha256 char(64) NOT NULL,
  result_sha256 char(64) NOT NULL,
  fetch_outcome text NOT NULL,
  source_url_redacted text,
  final_url_redacted text,
  source_authority text NOT NULL,
  retrieved_at timestamptz NOT NULL,
  http_status integer NOT NULL,
  content_media_type text NOT NULL,
  content_size_bytes bigint NOT NULL,
  content_sha256 char(64) NOT NULL,
  response_headers_sha256 char(64) NOT NULL,
  artifact_sha256 char(64) NOT NULL,
  object_key text NOT NULL,
  object_key_hash char(64) NOT NULL,
  safe_headers jsonb NOT NULL,
  safe_headers_canonical bytea NOT NULL,
  redirect_chain jsonb NOT NULL,
  redirect_chain_canonical bytea NOT NULL,
  classification text NOT NULL,
  content_safety_state text NOT NULL,
  content_safety_receipt_sha256 char(64) NOT NULL,
  artifact_canonical bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT research_artifacts_pk PRIMARY KEY (id)
);
ALTER TABLE raw.research_artifacts OWNER TO gurine_migrator;
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_asset_uk UNIQUE (asset_id, asset_revision);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_asset_binding_uk UNIQUE (id, asset_id, asset_revision, content_sha256);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_fetch_uk UNIQUE (source_fetch_id);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_call_ordinal_uk UNIQUE (agent_run_id, call_id, artifact_ordinal);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_citation_binding_uk UNIQUE (id, agent_run_id, content_sha256);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_source_use_binding_uk UNIQUE (id, asset_id, asset_revision, artifact_sha256, content_sha256, source_fetch_id);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_revision_ordinal_ck CHECK (asset_revision = 1 AND artifact_ordinal >= 0);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_request_kind_ck CHECK (request_kind IN ('SEARCH_PUBLIC_WEB','FETCH_URL'));
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_outcome_ck CHECK (fetch_outcome IN ('STORED','RENDER_REQUIRED','QUARANTINED'));
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_safety_ck CHECK (content_safety_state IN ('CLEAN','FLAGGED','QUARANTINED'));
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_http_size_ck CHECK (http_status BETWEEN 100 AND 599 AND content_size_bytes >= 0);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_url_ck CHECK (request_kind<>'FETCH_URL' OR (source_url_redacted IS NOT NULL AND final_url_redacted IS NOT NULL AND source_url_redacted LIKE 'https://%' AND final_url_redacted LIKE 'https://%'));
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_render_ck CHECK (fetch_outcome<>'RENDER_REQUIRED' OR content_media_type='text/html');
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_canonical_ck CHECK (convert_from(safe_headers_canonical,'UTF8')::jsonb=safe_headers AND convert_from(redirect_chain_canonical,'UTF8')::jsonb=redirect_chain AND encode(extensions.digest(artifact_canonical,'sha256'),'hex')=artifact_sha256);
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_safety_receipt_ck CHECK (content_safety_receipt_sha256 IS NOT NULL AND (fetch_outcome<>'STORED' OR content_safety_state IN ('CLEAN','FLAGGED','QUARANTINED')));
REVOKE ALL ON raw.research_artifacts FROM PUBLIC;
REVOKE ALL ON raw.research_artifacts FROM gurine_workflow_worker;
REVOKE ALL ON raw.research_artifacts FROM gurine_control_api;
REVOKE ALL ON raw.research_artifacts FROM gurine_analysis_worker;
REVOKE ALL ON raw.research_artifacts FROM gurine_public_projector;
REVOKE ALL ON raw.research_artifacts FROM gurine_notification_worker;
REVOKE ALL ON raw.research_artifacts FROM gurine_submission_api;
REVOKE ALL ON raw.research_artifacts FROM gurine_auditor;
GRANT SELECT, INSERT ON raw.research_artifacts TO gurine_analysis_worker;
GRANT SELECT ON raw.research_artifacts TO gurine_control_api;
GRANT SELECT ON raw.research_artifacts TO gurine_ingest_worker;
GRANT SELECT ON raw.research_artifacts TO gurine_workflow_worker;
CREATE TRIGGER raw_research_artifacts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON raw.research_artifacts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_output_validations (
  validation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid NOT NULL,
  input_snapshot_sha256 char(64) NOT NULL,
  provider_output_sha256 char(64) NOT NULL,
  validator_version text NOT NULL,
  validator_sha256 char(64) NOT NULL,
  output_schema_id text NOT NULL,
  output_schema_version text NOT NULL,
  output_schema_sha256 char(64) NOT NULL,
  validation_policy_version text NOT NULL,
  validation_policy_sha256 char(64) NOT NULL,
  validation_status text NOT NULL,
  schema_status text NOT NULL,
  citation_status text NOT NULL,
  policy_status text NOT NULL,
  run_terminal_status text NOT NULL,
  output_status text NOT NULL,
  failure_code text,
  failure_details_redacted jsonb NOT NULL,
  validated_outcome jsonb,
  validated_outcome_sha256 char(64),
  citation_count integer NOT NULL,
  proposal_count integer NOT NULL,
  citation_set_sha256 char(64) NOT NULL,
  proposal_set_sha256 char(64) NOT NULL,
  validation_sha256 char(64) NOT NULL,
  validated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_output_validations_pk PRIMARY KEY (validation_id)
);
ALTER TABLE ops.agent_output_validations OWNER TO gurine_migrator;
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_turn_uk UNIQUE (agent_run_id, provider_turn_id);
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_run_binding_uk UNIQUE (validation_id, agent_run_id, input_snapshot_sha256);
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_binding_uk UNIQUE (validation_id, agent_run_id, provider_turn_id, input_snapshot_sha256, provider_output_sha256, validation_sha256);
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_status_ck CHECK (validation_status IN ('VALID','INVALID') AND schema_status IN ('PASS','FAIL','NOT_RUN') AND citation_status IN ('PASS','FAIL','NOT_RUN') AND policy_status IN ('PASS','FAIL','NOT_RUN'));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_run_status_ck CHECK (run_terminal_status IN ('SUCCEEDED','FAILED','POLICY_BLOCKED','BUDGET_BLOCKED','CANCELLED') AND output_status IN ('COMPLETED','ABSTAINED','POLICY_BLOCKED','BUDGET_BLOCKED'));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_failure_code_ck CHECK (failure_code IS NULL OR failure_code IN ('OUTPUT_SCHEMA_INVALID','CITATION_MISSING','CITATION_OUTSIDE_SNAPSHOT','CITATION_LOCATOR_MISMATCH','CITATION_CONTENT_HASH_MISMATCH','CITATION_SOURCE_KIND_INVALID','RUN_TOOL_ARTIFACT_NOT_OWNED_BY_RUN','SNAPSHOT_STALE','PROMPT_INJECTION_DETECTED','RIGHTS_DENIED','CLASSIFICATION_DENIED','SOURCE_USE_MISSING','SOURCE_USE_RIGHTS_MISMATCH','PROPOSAL_SCHEMA_INVALID'));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_counts_ck CHECK (citation_count >= 0 AND proposal_count >= 0);
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_valid_ck CHECK (validation_status<>'VALID' OR (schema_status='PASS' AND citation_status='PASS' AND policy_status='PASS' AND failure_code IS NULL AND validated_outcome IS NOT NULL AND validated_outcome_sha256 IS NOT NULL));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_schema_failure_ck CHECK (schema_status<>'FAIL' OR (validation_status='INVALID' AND run_terminal_status='FAILED' AND failure_code IS NOT NULL AND failure_code='OUTPUT_SCHEMA_INVALID' AND citation_count=0 AND proposal_count=0 AND validated_outcome IS NULL));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_abstention_ck CHECK (output_status<>'ABSTAINED' OR (validation_status='INVALID' AND run_terminal_status='SUCCEEDED' AND proposal_count=0 AND failure_code IS NOT NULL AND failure_code IN ('CITATION_MISSING','CITATION_OUTSIDE_SNAPSHOT','CITATION_LOCATOR_MISMATCH','CITATION_CONTENT_HASH_MISMATCH','CITATION_SOURCE_KIND_INVALID','RUN_TOOL_ARTIFACT_NOT_OWNED_BY_RUN','SNAPSHOT_STALE','PROMPT_INJECTION_DETECTED','RIGHTS_DENIED','CLASSIFICATION_DENIED','SOURCE_USE_MISSING','SOURCE_USE_RIGHTS_MISMATCH','PROPOSAL_SCHEMA_INVALID')));
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_proposal_ck CHECK (output_status='COMPLETED' OR proposal_count=0);
REVOKE ALL ON ops.agent_output_validations FROM PUBLIC;
REVOKE ALL ON ops.agent_output_validations FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_output_validations FROM gurine_control_api;
REVOKE ALL ON ops.agent_output_validations FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_output_validations FROM gurine_public_projector;
REVOKE ALL ON ops.agent_output_validations FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_output_validations FROM gurine_submission_api;
REVOKE ALL ON ops.agent_output_validations FROM gurine_auditor;
GRANT SELECT, INSERT ON ops.agent_output_validations TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_output_validations TO gurine_control_api;
CREATE TRIGGER ops_agent_output_validations_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.agent_output_validations FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_proposal_citations (
  citation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  citation_contract_version smallint NOT NULL DEFAULT 2,
  proposal_id uuid NOT NULL,
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid NOT NULL,
  validation_id uuid NOT NULL,
  dataset_snapshot_id uuid NOT NULL,
  snapshot_member_id uuid,
  snapshot_member_digest char(64),
  citation_ordinal integer NOT NULL,
  input_snapshot_sha256 char(64) NOT NULL,
  proposal_payload_sha256 char(64) NOT NULL,
  source_kind text NOT NULL,
  source_use_id uuid NOT NULL,
  source_use_sha256 char(64) NOT NULL,
  evidence_segment_id uuid,
  research_artifact_id uuid,
  source_id uuid NOT NULL,
  locator_kind text NOT NULL,
  locator_value text NOT NULL,
  locator_digest char(64) NOT NULL,
  content_sha256 char(64) NOT NULL,
  supports_redacted text NOT NULL,
  supports_sha256 char(64) NOT NULL,
  citation_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_proposal_citations_pk PRIMARY KEY (citation_id)
);
ALTER TABLE ops.agent_proposal_citations OWNER TO gurine_migrator;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_ordinal_uk UNIQUE (proposal_id, citation_ordinal);
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_digest_uk UNIQUE (proposal_id, citation_digest);
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_version_ordinal_ck CHECK (citation_contract_version = 2 AND citation_ordinal >= 0);
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_kind_ck CHECK (source_kind IN ('EVIDENCE_SEGMENT','RUN_TOOL_ARTIFACT'));
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_source_shape_ck CHECK (num_nonnulls(evidence_segment_id,research_artifact_id)=1 AND ((source_kind='EVIDENCE_SEGMENT' AND evidence_segment_id IS NOT NULL AND snapshot_member_id IS NOT NULL AND snapshot_member_digest IS NOT NULL) OR (source_kind='RUN_TOOL_ARTIFACT' AND research_artifact_id IS NOT NULL AND snapshot_member_id IS NULL AND snapshot_member_digest IS NULL)));
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_locator_kind_ck CHECK (locator_kind IN ('PAGE_BBOX','XLSX_CELL','CSV_ROW_COLUMN','XML_XPATH','DOCX_PARAGRAPH','HWPX_XPATH','JSON_POINTER','HTML_CSS_SELECTOR','API_FIELD','TEXT_RANGE','IMAGE_BBOX','AUDIO_TIME_RANGE','VIDEO_TIME_RANGE','VIDEO_REGION_TIME'));
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_nonempty_ck CHECK (length(btrim(locator_value)) > 0 AND length(btrim(supports_redacted)) > 0);
REVOKE ALL ON ops.agent_proposal_citations FROM PUBLIC;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_control_api;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_public_projector;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_submission_api;
REVOKE ALL ON ops.agent_proposal_citations FROM gurine_auditor;
GRANT SELECT, INSERT ON ops.agent_proposal_citations TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_proposal_citations TO gurine_control_api;
CREATE TRIGGER ops_agent_proposal_citations_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.agent_proposal_citations FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE raw.asset_rights_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL,
  asset_sha256 char(64) NOT NULL,
  asset_revision bigint NOT NULL,
  decision_version bigint NOT NULL,
  prior_decision_id uuid,
  prior_decision_version bigint,
  prior_decision_sha256 char(64),
  asset_kind text NOT NULL,
  source_document_id uuid,
  research_artifact_id uuid,
  decision_kind text NOT NULL,
  access_right text NOT NULL,
  private_storage_right text NOT NULL,
  model_egress_right text NOT NULL,
  model_use_right text NOT NULL,
  derivative_creation_right text NOT NULL,
  excerpt_right text NOT NULL,
  redistribution_right text NOT NULL,
  commercial_use_right text NOT NULL,
  public_display_right text NOT NULL,
  dimensions_sha256 char(64) NOT NULL,
  legal_basis_code text NOT NULL,
  legal_basis_reference text NOT NULL,
  legal_basis_sha256 char(64) NOT NULL,
  license_evidence_digests text[] NOT NULL,
  license_evidence_set_sha256 char(64) NOT NULL,
  jurisdiction text NOT NULL,
  attribution_required boolean NOT NULL,
  attribution_text text,
  attribution_uri text,
  attribution_sha256 char(64) NOT NULL,
  policy_version text NOT NULL,
  policy_sha256 char(64) NOT NULL,
  approval_sha256 char(64) NOT NULL,
  execution_sha256 char(64) NOT NULL,
  evidence_receipt_id uuid NOT NULL,
  evidence_receipt_sha256 char(64) NOT NULL,
  reviewer_user_id uuid NOT NULL,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz,
  decision_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT asset_rights_decisions_pk PRIMARY KEY (id)
);
ALTER TABLE raw.asset_rights_decisions OWNER TO gurine_migrator;
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_version_uk UNIQUE (asset_id, asset_revision, asset_sha256, decision_version);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_digest_uk UNIQUE (asset_id, asset_revision, asset_sha256, decision_sha256);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_binding_uk UNIQUE (id, decision_sha256);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_source_use_binding_uk UNIQUE (id, asset_id, asset_revision, asset_sha256, decision_version, decision_sha256);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_identity_ck CHECK (asset_revision > 0 AND decision_version > 0 AND num_nonnulls(source_document_id,research_artifact_id)=1);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_kind_ck CHECK ((asset_kind='SOURCE_DOCUMENT' AND source_document_id IS NOT NULL) OR (asset_kind='RESEARCH_ARTIFACT' AND research_artifact_id IS NOT NULL));
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_decision_kind_ck CHECK (decision_kind IN ('GRANT','DENY','SUSPEND','REVOKE'));
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_dimensions_ck CHECK (access_right IN ('ALLOW','DENY','UNKNOWN') AND private_storage_right IN ('ALLOW','DENY','UNKNOWN') AND model_egress_right IN ('ALLOW','DENY','UNKNOWN') AND model_use_right IN ('ALLOW','DENY','UNKNOWN') AND derivative_creation_right IN ('ALLOW','DENY','UNKNOWN') AND excerpt_right IN ('ALLOW','DENY','UNKNOWN') AND redistribution_right IN ('ALLOW','DENY','UNKNOWN') AND commercial_use_right IN ('ALLOW','DENY','UNKNOWN') AND public_display_right IN ('ALLOW','DENY','UNKNOWN'));
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_sequence_ck CHECK ((decision_version=1 AND prior_decision_id IS NULL AND prior_decision_version IS NULL AND prior_decision_sha256 IS NULL) OR (decision_version>1 AND prior_decision_id IS NOT NULL AND prior_decision_version IS NOT NULL AND prior_decision_version=decision_version-1 AND prior_decision_sha256 IS NOT NULL));
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_effective_range_ck CHECK (expires_at IS NULL OR expires_at > effective_at);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_attribution_ck CHECK (NOT attribution_required OR (attribution_text IS NOT NULL AND length(btrim(attribution_text)) > 0));
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_nonempty_ck CHECK (length(btrim(legal_basis_code)) > 0 AND length(btrim(legal_basis_reference)) > 0 AND length(btrim(jurisdiction)) > 0 AND length(btrim(policy_version)) > 0);
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_license_set_ck CHECK (ops.digest_array_is_sorted_unique(license_evidence_digests));
REVOKE ALL ON raw.asset_rights_decisions FROM PUBLIC;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_workflow_worker;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_control_api;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_analysis_worker;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_public_projector;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_notification_worker;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_submission_api;
REVOKE ALL ON raw.asset_rights_decisions FROM gurine_auditor;
GRANT SELECT, INSERT ON raw.asset_rights_decisions TO gurine_workflow_worker;
GRANT SELECT ON raw.asset_rights_decisions TO gurine_control_api;
GRANT SELECT ON raw.asset_rights_decisions TO gurine_analysis_worker;
GRANT SELECT ON raw.asset_rights_decisions TO gurine_ingest_worker;
GRANT SELECT ON raw.asset_rights_decisions TO gurine_document_extractor;
CREATE TRIGGER raw_asset_rights_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON raw.asset_rights_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_reconciliation_evidence (
  evidence_id uuid NOT NULL DEFAULT gen_random_uuid(),
  evidence_contract_version smallint NOT NULL DEFAULT 1,
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid,
  tool_call_id uuid,
  evidence_kind text NOT NULL,
  source_proof_kind text NOT NULL,
  adapter_id text NOT NULL,
  adapter_version text NOT NULL,
  adapter_configuration_sha256 char(64) NOT NULL,
  lookup_request_sha256 char(64) NOT NULL,
  lookup_idempotency_key_sha256 char(64) NOT NULL,
  caller_assertion_sha256 char(64) NOT NULL,
  provider_receipt_id uuid,
  provider_receipt_sha256 char(64),
  tool_terminal_sha256 char(64),
  resolution text NOT NULL,
  budget_disposition text NOT NULL,
  observed_at timestamptz NOT NULL,
  evidence_canonical bytea NOT NULL,
  evidence_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_reconciliation_evidence_pk PRIMARY KEY (evidence_id)
);
ALTER TABLE ops.agent_reconciliation_evidence OWNER TO gurine_migrator;
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_binding_uk UNIQUE (agent_run_id, evidence_id, evidence_sha256);
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_lookup_uk UNIQUE (agent_run_id, lookup_idempotency_key_sha256, lookup_request_sha256);
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_kind_ck CHECK (evidence_contract_version=1 AND evidence_kind IN ('PROVIDER_LOOKUP','IDEMPOTENCY_LOOKUP','TOOL_ADAPTER_LOOKUP','COST_USAGE_RECEIPT','DEFINITIVE_NO_DISPATCH'));
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_source_kind_ck CHECK (source_proof_kind IN ('AUTHENTICATED_RESPONSE_HEADERS','SIGNED_PROVIDER_RECEIPT','IDEMPOTENCY_LOOKUP','USAGE_LOOKUP','TOOL_ADAPTER_TERMINAL_RECEIPT','DEFINITIVE_NO_DISPATCH'));
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_resolution_ck CHECK (resolution IN ('STILL_AMBIGUOUS','SAFE_RETRY_AUTHORIZED','RESUME_RECOVERED_RESULT','TERMINAL_SUCCEEDED','TERMINAL_FAILED','TERMINAL_CANCELLED') AND budget_disposition IN ('NONE','SETTLED','RELEASED','RECONCILIATION_REQUIRED'));
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_target_ck CHECK ((evidence_kind='TOOL_ADAPTER_LOOKUP' AND provider_turn_id IS NULL AND provider_receipt_id IS NULL AND provider_receipt_sha256 IS NULL AND tool_call_id IS NOT NULL AND tool_terminal_sha256 IS NOT NULL) OR (evidence_kind IN ('PROVIDER_LOOKUP','IDEMPOTENCY_LOOKUP','COST_USAGE_RECEIPT') AND provider_turn_id IS NOT NULL AND tool_call_id IS NULL AND tool_terminal_sha256 IS NULL) OR (evidence_kind='DEFINITIVE_NO_DISPATCH' AND provider_turn_id IS NULL AND tool_call_id IS NULL AND provider_receipt_id IS NULL AND provider_receipt_sha256 IS NULL AND tool_terminal_sha256 IS NULL));
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_provider_pair_ck CHECK ((provider_receipt_id IS NULL)=(provider_receipt_sha256 IS NULL));
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_ambiguous_ck CHECK (resolution<>'STILL_AMBIGUOUS' OR budget_disposition='RECONCILIATION_REQUIRED');
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_nonempty_ck CHECK (length(btrim(adapter_id))>0 AND length(btrim(adapter_version))>0);
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_canonical_ck CHECK (convert_from(evidence_canonical,'UTF8')::jsonb IS NOT NULL);
REVOKE ALL ON ops.agent_reconciliation_evidence FROM PUBLIC;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_control_api;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_public_projector;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_submission_api;
REVOKE ALL ON ops.agent_reconciliation_evidence FROM gurine_auditor;
GRANT SELECT ON ops.agent_reconciliation_evidence TO gurine_control_api;
GRANT SELECT ON ops.agent_reconciliation_evidence TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_reconciliation_evidence TO gurine_auditor;
CREATE TRIGGER ops_agent_reconciliation_evidence_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.agent_reconciliation_evidence FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_run_control_receipts (
  receipt_id uuid NOT NULL DEFAULT gen_random_uuid(),
  receipt_contract_version smallint NOT NULL DEFAULT 2,
  agent_run_id uuid NOT NULL,
  aggregate_version bigint NOT NULL,
  prior_status text,
  prior_control_state text,
  next_status text NOT NULL,
  next_control_state text NOT NULL,
  affected_provider_turn_id uuid,
  affected_tool_call_id uuid,
  reconciliation_evidence_id uuid,
  reconciliation_evidence_sha256 char(64),
  proof_kind text NOT NULL,
  proof_sha256 char(64) NOT NULL,
  budget_disposition text NOT NULL,
  budget_resolution_set_sha256 char(64) NOT NULL,
  actor_kind text NOT NULL,
  actor_id uuid,
  reason_code text NOT NULL,
  reason_sha256 char(64) NOT NULL,
  command_operation_id text,
  command_expected_run_version bigint,
  command_idempotency_key_sha256 char(64),
  command_request_sha256 char(64),
  prior_receipt_id uuid,
  prior_receipt_sha256 char(64),
  audit_event_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_run_control_receipts_pk PRIMARY KEY (receipt_id)
);
ALTER TABLE ops.agent_run_control_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_version_uk UNIQUE (agent_run_id, aggregate_version);
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_digest_uk UNIQUE (agent_run_id, receipt_sha256);
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_binding_uk UNIQUE (agent_run_id, receipt_id, receipt_sha256);
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_version_ck CHECK (receipt_contract_version=2 AND aggregate_version > 0 AND ((aggregate_version=1 AND prior_receipt_id IS NULL AND prior_receipt_sha256 IS NULL AND prior_status IS NULL AND prior_control_state IS NULL) OR (aggregate_version>1 AND prior_receipt_id IS NOT NULL AND prior_receipt_sha256 IS NOT NULL AND prior_status IS NOT NULL AND prior_control_state IS NOT NULL)));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_status_ck CHECK ((prior_status IS NULL OR prior_status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED')) AND next_status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_control_ck CHECK ((prior_control_state IS NULL OR prior_control_state IN ('NONE','ACTIVE','CANCEL_REQUESTED','RECONCILIATION_REQUIRED','SETTLED')) AND next_control_state IN ('NONE','ACTIVE','CANCEL_REQUESTED','RECONCILIATION_REQUIRED','SETTLED'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_terminal_ck CHECK ((next_status IN ('SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED'))=(next_control_state='SETTLED'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_proof_ck CHECK (proof_kind IN ('COMMAND_INPUT','LEASE_CLAIM','PROVIDER_LOOKUP','IDEMPOTENCY_LOOKUP','TOOL_ADAPTER_LOOKUP','COST_USAGE_RECEIPT','DEFINITIVE_NO_DISPATCH','VALIDATED_FINAL_OUTPUT','DEFINITIVE_INTERNAL_FAILURE') AND budget_disposition IN ('NONE','RESERVED','SETTLED','RELEASED','RECONCILIATION_REQUIRED') AND actor_kind IN ('CONTROL_API','ANALYSIS_WORKER','RECONCILIATION_WORKER','SCHEDULER'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_actor_ck CHECK ((actor_kind='SCHEDULER' AND actor_id IS NULL) OR (actor_kind<>'SCHEDULER' AND actor_id IS NOT NULL));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_reconciliation_ck CHECK ((reconciliation_evidence_id IS NULL)=(reconciliation_evidence_sha256 IS NULL) AND (proof_kind NOT IN ('PROVIDER_LOOKUP','IDEMPOTENCY_LOOKUP','TOOL_ADAPTER_LOOKUP','COST_USAGE_RECEIPT') OR reconciliation_evidence_id IS NOT NULL));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_command_ck CHECK ((actor_kind='CONTROL_API' AND command_operation_id='cancelAgentRun' AND command_expected_run_version IS NOT NULL AND command_expected_run_version>0 AND command_idempotency_key_sha256 IS NOT NULL AND command_request_sha256 IS NOT NULL) OR (actor_kind='RECONCILIATION_WORKER' AND command_operation_id='reconcileAgentRun' AND command_expected_run_version IS NOT NULL AND command_expected_run_version>0 AND command_idempotency_key_sha256 IS NOT NULL AND command_request_sha256 IS NOT NULL) OR (actor_kind IN ('ANALYSIS_WORKER','SCHEDULER') AND command_operation_id IS NULL AND command_expected_run_version IS NULL AND command_idempotency_key_sha256 IS NULL AND command_request_sha256 IS NULL));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_reason_ck CHECK (reason_code IN ('RUN_STARTED','TURN_ADVANCED','FINAL_OUTPUT_VALIDATED','DEFINITIVE_FAILURE','BUDGET_DENIED','POLICY_DENIED','PRE_DISPATCH_CANCELLED','CANCEL_REQUESTED','OUTCOME_AMBIGUOUS','SAFE_RETRY_AUTHORIZED','RECONCILED_SUCCEEDED','RECONCILED_FAILED','RECONCILED_CANCELLED','NO_STATE_CHANGE'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_safe_retry_ck CHECK (NOT (prior_control_state='CANCEL_REQUESTED' AND next_control_state='ACTIVE') AND (next_control_state<>'ACTIVE' OR prior_control_state='RECONCILIATION_REQUIRED'));
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_canonical_ck CHECK (convert_from(receipt_canonical,'UTF8')::jsonb IS NOT NULL);
REVOKE ALL ON ops.agent_run_control_receipts FROM PUBLIC;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_control_api;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.agent_run_control_receipts FROM gurine_auditor;
GRANT SELECT ON ops.agent_run_control_receipts TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_run_control_receipts TO gurine_control_api;
GRANT SELECT ON ops.agent_run_control_receipts TO gurine_auditor;
CREATE TRIGGER ops_agent_run_control_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.agent_run_control_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.agent_source_uses (
  source_use_id uuid NOT NULL DEFAULT gen_random_uuid(),
  source_use_contract_version smallint NOT NULL DEFAULT 2,
  agent_run_id uuid NOT NULL,
  provider_turn_id uuid,
  tool_call_id uuid,
  parent_source_use_id uuid,
  parent_source_use_sha256 char(64),
  promotion_id uuid,
  promotion_receipt_sha256 char(64),
  use_kind text NOT NULL,
  source_kind text NOT NULL,
  dataset_snapshot_id uuid,
  snapshot_member_id uuid,
  snapshot_member_digest char(64),
  snapshot_member_source_id uuid,
  snapshot_member_source_digest char(64),
  member_source_kind text,
  object_type text,
  object_id uuid,
  object_version bigint,
  object_content_sha256 char(64),
  evidence_segment_id uuid,
  source_document_id uuid,
  source_asset_id uuid,
  source_asset_revision bigint,
  source_content_sha256 char(64),
  response_id uuid,
  response_version bigint,
  response_content_sha256 char(64),
  response_publication_consent_sha256 char(64),
  research_artifact_id uuid,
  research_asset_id uuid,
  research_asset_revision bigint,
  research_artifact_sha256 char(64),
  research_content_sha256 char(64),
  research_source_fetch_id uuid,
  locator_kind text,
  locator_value text,
  locator_sha256 char(64),
  selected_content_sha256 char(64),
  classification text NOT NULL,
  rights_binding_kind text NOT NULL,
  rights_asset_id uuid,
  rights_asset_revision bigint,
  rights_asset_sha256 char(64),
  asset_rights_decision_id uuid,
  asset_rights_decision_version bigint,
  asset_rights_decision_sha256 char(64),
  rights_effective_at timestamptz NOT NULL,
  rights_expires_at timestamptz,
  access_right text NOT NULL,
  private_storage_right text NOT NULL,
  model_egress_right text NOT NULL,
  model_use_right text NOT NULL,
  derivative_creation_right text NOT NULL,
  excerpt_right text NOT NULL,
  redistribution_right text NOT NULL,
  commercial_use_right text NOT NULL,
  public_display_right text NOT NULL,
  rights_policy_version text NOT NULL,
  rights_policy_sha256 char(64) NOT NULL,
  provider_receipt_id uuid,
  provider_receipt_sha256 char(64),
  occurred_at timestamptz NOT NULL,
  source_use_canonical bytea NOT NULL,
  source_use_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT agent_source_uses_pk PRIMARY KEY (source_use_id)
);
ALTER TABLE ops.agent_source_uses OWNER TO gurine_migrator;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_run_digest_uk UNIQUE (agent_run_id, source_use_sha256);
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_binding_uk UNIQUE (agent_run_id, source_use_id, source_use_sha256);
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_version_kind_ck CHECK (source_use_contract_version=2 AND use_kind IN ('TOOL_QUERY','TOOL_RESULT','MODEL_INPUT','MODEL_OUTPUT_DERIVATION','CITATION','PROPOSAL','HUMAN_PROMOTION') AND source_kind IN ('EVIDENCE_SEGMENT','RESPONSE_SNAPSHOT','DATASET_MEMBER','RESEARCH_ARTIFACT'));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_parent_ck CHECK ((use_kind='TOOL_QUERY' AND parent_source_use_id IS NULL AND parent_source_use_sha256 IS NULL) OR (use_kind<>'TOOL_QUERY' AND parent_source_use_id IS NOT NULL AND parent_source_use_sha256 IS NOT NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_tool_ck CHECK ((use_kind='TOOL_QUERY' AND ((source_kind='DATASET_MEMBER' AND tool_call_id IS NULL AND provider_turn_id IS NULL) OR (tool_call_id IS NOT NULL AND provider_turn_id IS NOT NULL))) OR (use_kind='TOOL_RESULT' AND tool_call_id IS NOT NULL AND provider_turn_id IS NOT NULL) OR (use_kind NOT IN ('TOOL_QUERY','TOOL_RESULT') AND tool_call_id IS NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_provider_ck CHECK ((use_kind IN ('MODEL_INPUT','MODEL_OUTPUT_DERIVATION'))=(provider_receipt_id IS NOT NULL AND provider_receipt_sha256 IS NOT NULL AND provider_turn_id IS NOT NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_promotion_ck CHECK ((use_kind='HUMAN_PROMOTION' AND source_kind='RESEARCH_ARTIFACT' AND promotion_id IS NOT NULL AND promotion_receipt_sha256 IS NOT NULL) OR (use_kind<>'HUMAN_PROMOTION' AND promotion_id IS NULL AND promotion_receipt_sha256 IS NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_locator_ck CHECK ((locator_kind IS NULL AND locator_value IS NULL AND locator_sha256 IS NULL) OR (locator_kind IN ('PAGE_BBOX','XLSX_CELL','CSV_ROW_COLUMN','XML_XPATH','DOCX_PARAGRAPH','HWPX_XPATH','JSON_POINTER','HTML_CSS_SELECTOR','API_FIELD','TEXT_RANGE','IMAGE_BBOX','AUDIO_TIME_RANGE','VIDEO_TIME_RANGE','VIDEO_REGION_TIME') AND locator_value IS NOT NULL AND length(btrim(locator_value)) BETWEEN 1 AND 2048 AND locator_sha256 IS NOT NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_member_source_kind_ck CHECK (member_source_kind IS NULL OR member_source_kind IN ('SOURCE_DOCUMENT','RESPONSE'));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_rights_dimension_ck CHECK (access_right IN ('ALLOW','DENY','UNKNOWN') AND private_storage_right IN ('ALLOW','DENY','UNKNOWN') AND model_egress_right IN ('ALLOW','DENY','UNKNOWN') AND model_use_right IN ('ALLOW','DENY','UNKNOWN') AND derivative_creation_right IN ('ALLOW','DENY','UNKNOWN') AND excerpt_right IN ('ALLOW','DENY','UNKNOWN') AND redistribution_right IN ('ALLOW','DENY','UNKNOWN') AND commercial_use_right IN ('ALLOW','DENY','UNKNOWN') AND public_display_right IN ('ALLOW','DENY','UNKNOWN') AND (rights_expires_at IS NULL OR rights_expires_at > rights_effective_at));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_rights_binding_ck CHECK ((rights_binding_kind='ASSET_RIGHTS' AND rights_asset_id IS NOT NULL AND rights_asset_revision > 0 AND rights_asset_sha256 IS NOT NULL AND asset_rights_decision_id IS NOT NULL AND asset_rights_decision_version > 0 AND asset_rights_decision_sha256 IS NOT NULL AND response_publication_consent_sha256 IS NULL AND ((source_kind IN ('EVIDENCE_SEGMENT','DATASET_MEMBER') AND rights_asset_id=source_asset_id AND rights_asset_revision=source_asset_revision AND rights_asset_sha256=source_content_sha256) OR (source_kind='RESEARCH_ARTIFACT' AND rights_asset_id=research_asset_id AND rights_asset_revision=research_asset_revision AND rights_asset_sha256=research_content_sha256))) OR (rights_binding_kind='RESPONSE_CONSENT' AND rights_asset_id IS NULL AND rights_asset_revision IS NULL AND rights_asset_sha256 IS NULL AND asset_rights_decision_id IS NULL AND asset_rights_decision_version IS NULL AND asset_rights_decision_sha256 IS NULL AND source_kind='RESPONSE_SNAPSHOT' AND response_id IS NOT NULL AND response_publication_consent_sha256 IS NOT NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_source_shape_ck CHECK ((source_kind='EVIDENCE_SEGMENT'
 AND dataset_snapshot_id IS NOT NULL AND snapshot_member_id IS NOT NULL
 AND snapshot_member_digest IS NOT NULL AND snapshot_member_source_id IS NOT NULL
 AND snapshot_member_source_digest IS NOT NULL AND member_source_kind='SOURCE_DOCUMENT'
 AND object_type='EVIDENCE_SEGMENT' AND object_id IS NOT NULL
 AND object_version IS NOT NULL AND object_version > 0 AND object_content_sha256 IS NOT NULL
 AND evidence_segment_id IS NOT NULL AND evidence_segment_id=object_id
 AND source_document_id IS NOT NULL AND source_asset_id IS NOT NULL
 AND source_asset_revision IS NOT NULL AND source_asset_revision > 0
 AND source_content_sha256 IS NOT NULL AND selected_content_sha256 IS NOT NULL
 AND locator_sha256 IS NOT NULL
 AND response_id IS NULL AND response_version IS NULL AND response_content_sha256 IS NULL
 AND research_artifact_id IS NULL AND research_asset_id IS NULL
 AND research_asset_revision IS NULL AND research_artifact_sha256 IS NULL
 AND research_content_sha256 IS NULL AND research_source_fetch_id IS NULL)
OR (source_kind='RESPONSE_SNAPSHOT'
 AND dataset_snapshot_id IS NOT NULL AND snapshot_member_id IS NOT NULL
 AND snapshot_member_digest IS NOT NULL AND snapshot_member_source_id IS NOT NULL
 AND snapshot_member_source_digest IS NOT NULL AND member_source_kind='RESPONSE'
 AND object_type='RESPONSE' AND object_id IS NOT NULL
 AND object_version IS NOT NULL AND object_version > 0 AND object_content_sha256 IS NOT NULL
 AND response_id IS NOT NULL AND response_id=object_id
 AND response_version IS NOT NULL AND response_version=object_version
 AND response_content_sha256 IS NOT NULL AND response_content_sha256=object_content_sha256
 AND source_document_id IS NULL AND source_asset_id IS NULL
 AND source_asset_revision IS NULL AND source_content_sha256 IS NULL
 AND evidence_segment_id IS NULL
 AND research_artifact_id IS NULL AND research_asset_id IS NULL
 AND research_asset_revision IS NULL AND research_artifact_sha256 IS NULL
 AND research_content_sha256 IS NULL AND research_source_fetch_id IS NULL)
OR (source_kind='DATASET_MEMBER'
 AND dataset_snapshot_id IS NOT NULL AND snapshot_member_id IS NOT NULL
 AND snapshot_member_digest IS NOT NULL AND snapshot_member_source_id IS NOT NULL
 AND snapshot_member_source_digest IS NOT NULL AND member_source_kind='SOURCE_DOCUMENT'
 AND object_type IN ('AGENCY','SUPPLIER','CONTRACT','CONTRACT_LINE_ITEM','CONTRACT_CHANGE','PRICE_OBSERVATION')
 AND object_id IS NOT NULL AND object_version IS NOT NULL AND object_version > 0
 AND object_content_sha256 IS NOT NULL
 AND source_document_id IS NOT NULL AND source_asset_id IS NOT NULL
 AND source_asset_revision IS NOT NULL AND source_asset_revision > 0
 AND source_content_sha256 IS NOT NULL
 AND evidence_segment_id IS NULL
 AND response_id IS NULL AND response_version IS NULL AND response_content_sha256 IS NULL
 AND research_artifact_id IS NULL AND research_asset_id IS NULL
 AND research_asset_revision IS NULL AND research_artifact_sha256 IS NULL
 AND research_content_sha256 IS NULL AND research_source_fetch_id IS NULL)
OR (source_kind='RESEARCH_ARTIFACT'
 AND dataset_snapshot_id IS NULL AND snapshot_member_id IS NULL
 AND snapshot_member_digest IS NULL AND snapshot_member_source_id IS NULL
 AND snapshot_member_source_digest IS NULL AND member_source_kind IS NULL
 AND object_type IS NULL AND object_id IS NULL AND object_version IS NULL
 AND object_content_sha256 IS NULL AND evidence_segment_id IS NULL
 AND source_document_id IS NULL AND source_asset_id IS NULL
 AND source_asset_revision IS NULL AND source_content_sha256 IS NULL
 AND response_id IS NULL AND response_version IS NULL AND response_content_sha256 IS NULL
 AND response_publication_consent_sha256 IS NULL
 AND research_artifact_id IS NOT NULL AND research_asset_id IS NOT NULL
 AND research_asset_revision IS NOT NULL AND research_asset_revision=1
 AND research_artifact_sha256 IS NOT NULL AND research_content_sha256 IS NOT NULL
 AND research_source_fetch_id IS NOT NULL));
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_canonical_ck CHECK (convert_from(source_use_canonical,'UTF8')::jsonb IS NOT NULL);
REVOKE ALL ON ops.agent_source_uses FROM PUBLIC;
REVOKE ALL ON ops.agent_source_uses FROM gurine_workflow_worker;
REVOKE ALL ON ops.agent_source_uses FROM gurine_control_api;
REVOKE ALL ON ops.agent_source_uses FROM gurine_analysis_worker;
REVOKE ALL ON ops.agent_source_uses FROM gurine_public_projector;
REVOKE ALL ON ops.agent_source_uses FROM gurine_notification_worker;
REVOKE ALL ON ops.agent_source_uses FROM gurine_submission_api;
REVOKE ALL ON ops.agent_source_uses FROM gurine_auditor;
GRANT SELECT, INSERT ON ops.agent_source_uses TO gurine_analysis_worker;
GRANT SELECT ON ops.agent_source_uses TO gurine_control_api;
GRANT SELECT ON ops.agent_source_uses TO gurine_auditor;
CREATE TRIGGER ops_agent_source_uses_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.agent_source_uses FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE raw.research_artifact_promotions (
  promotion_id uuid NOT NULL DEFAULT gen_random_uuid(),
  promotion_contract_version smallint NOT NULL DEFAULT 1,
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  case_version bigint NOT NULL,
  agent_run_id uuid NOT NULL,
  research_artifact_id uuid NOT NULL,
  research_asset_id uuid NOT NULL,
  research_asset_revision bigint NOT NULL,
  research_artifact_sha256 char(64) NOT NULL,
  research_content_sha256 char(64) NOT NULL,
  research_source_fetch_id uuid NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  primary_evidence_segment_id uuid NOT NULL,
  primary_locator_sha256 char(64) NOT NULL,
  primary_selected_content_sha256 char(64) NOT NULL,
  selected_segment_bindings jsonb NOT NULL,
  selected_segment_bindings_canonical bytea NOT NULL,
  selected_segment_count integer NOT NULL,
  selected_segment_set_sha256 char(64) NOT NULL,
  evidence_id uuid NOT NULL,
  evidence_version bigint NOT NULL,
  evidence_digest char(64) NOT NULL,
  rights_decision_id uuid NOT NULL,
  rights_decision_version bigint NOT NULL,
  rights_decision_sha256 char(64) NOT NULL,
  root_source_use_id uuid NOT NULL,
  root_source_use_sha256 char(64) NOT NULL,
  reviewer_user_id uuid NOT NULL,
  reason_sha256 char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  promoted_at timestamptz NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT research_artifact_promotions_pk PRIMARY KEY (promotion_id)
);
ALTER TABLE raw.research_artifact_promotions OWNER TO gurine_migrator;
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_artifact_idempotency_uk UNIQUE (research_artifact_id, research_artifact_sha256, idempotency_key_sha256);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_evidence_uk UNIQUE (evidence_id, evidence_version);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_receipt_uk UNIQUE (receipt_sha256);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_binding_uk UNIQUE (promotion_id, receipt_sha256);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_version_ck CHECK (promotion_contract_version=1 AND expected_case_version > 0 AND case_version=expected_case_version+1 AND research_asset_revision=1 AND source_asset_revision > 0 AND evidence_version > 0 AND rights_decision_version > 0 AND selected_segment_count BETWEEN 1 AND 100);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_source_distinct_ck CHECK (research_asset_id<>source_asset_id AND research_content_sha256=source_content_sha256);
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_canonical_ck CHECK (convert_from(selected_segment_bindings_canonical,'UTF8')::jsonb=selected_segment_bindings AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload);
REVOKE ALL ON raw.research_artifact_promotions FROM PUBLIC;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_workflow_worker;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_control_api;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_analysis_worker;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_public_projector;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_notification_worker;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_submission_api;
REVOKE ALL ON raw.research_artifact_promotions FROM gurine_auditor;
GRANT SELECT ON raw.research_artifact_promotions TO gurine_control_api;
GRANT SELECT ON raw.research_artifact_promotions TO gurine_analysis_worker;
GRANT SELECT ON raw.research_artifact_promotions TO gurine_auditor;
CREATE TRIGGER raw_research_artifact_promotions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON raw.research_artifact_promotions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE public.search_documents (
  projection_generation_id uuid NOT NULL,
  snapshot_kind text NOT NULL DEFAULT 'PUBLIC_SEARCH_PROJECTION',
  producer_generation bigint NOT NULL,
  projection_watermark bigint NOT NULL,
  snapshot_contract_version smallint NOT NULL,
  member_ordinal bigint NOT NULL,
  member_digest char(64) NOT NULL,
  document_watermark bigint NOT NULL,
  origin_kind text NOT NULL,
  source_event_id uuid,
  source_event_type text NOT NULL,
  source_event_version integer NOT NULL,
  source_object_sha256 char(64) NOT NULL,
  object_type text NOT NULL,
  object_type_order smallint NOT NULL,
  object_id text NOT NULL,
  object_revision bigint NOT NULL,
  eligibility_state text NOT NULL,
  publication_state text,
  status text NOT NULL,
  search_date date NOT NULL,
  search_date_basis text NOT NULL,
  identifier_text text,
  normalized_identifier_key text,
  canonical_title text,
  canonical_name text,
  normalized_title text NOT NULL,
  verified_aliases text[] NOT NULL DEFAULT '{}'::text[],
  normalized_verified_aliases text[] NOT NULL DEFAULT '{}'::text[],
  verified_alias_source_document_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  authorized_summary text,
  authorized_body text,
  authorized_locator text,
  identifier_tokens text NOT NULL DEFAULT '',
  canonical_title_tokens text NOT NULL DEFAULT '',
  canonical_name_tokens text NOT NULL DEFAULT '',
  verified_alias_tokens text NOT NULL DEFAULT '',
  authorized_summary_tokens text NOT NULL DEFAULT '',
  authorized_body_tokens text NOT NULL DEFAULT '',
  locator_tokens text NOT NULL DEFAULT '',
  search_vector tsvector NOT NULL,
  href text NOT NULL,
  freshness_as_of timestamptz NOT NULL,
  last_successful_fetch_at timestamptz,
  expected_frequency_seconds bigint,
  lag_seconds bigint,
  freshness_status text NOT NULL,
  source_updated_at timestamptz NOT NULL,
  indexed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ranking_policy_version text NOT NULL DEFAULT 'search-rank-v1',
  normalizer_version text NOT NULL,
  normalizer_sha256 char(64) NOT NULL,
  document_digest char(64) NOT NULL,
  CONSTRAINT public_search_documents_pk PRIMARY KEY (projection_generation_id, object_type, object_id, object_revision)
);
ALTER TABLE public.search_documents OWNER TO gurine_migrator;
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_member_uk UNIQUE (projection_generation_id, member_ordinal);
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_member_digest_uk UNIQUE (projection_generation_id, member_digest);
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_object_uk UNIQUE (projection_generation_id, object_type, object_id);
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_event_object_uk UNIQUE (projection_generation_id, source_event_id, object_type, object_id, object_revision);
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_kind_ck CHECK (snapshot_kind='PUBLIC_SEARCH_PROJECTION');
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_type_ck CHECK (object_type IN ('CASE','CONTRACT','AGENCY','SUPPLIER','METHODOLOGY','CORRECTION'));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_type_order_ck CHECK ((object_type='CASE' AND object_type_order=1) OR (object_type='CONTRACT' AND object_type_order=2) OR (object_type='AGENCY' AND object_type_order=3) OR (object_type='SUPPLIER' AND object_type_order=4) OR (object_type='METHODOLOGY' AND object_type_order=5) OR (object_type='CORRECTION' AND object_type_order=6));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_positive_ck CHECK (producer_generation > 0 AND projection_watermark >= 0 AND member_ordinal >= 0 AND document_watermark BETWEEN 0 AND projection_watermark AND source_event_version > 0 AND object_revision > 0);
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_origin_ck CHECK (origin_kind IN ('EVENT','DETERMINISTIC_BACKFILL') AND ((origin_kind='EVENT' AND source_event_id IS NOT NULL) OR (origin_kind='DETERMINISTIC_BACKFILL' AND source_event_id IS NULL AND document_watermark=projection_watermark)));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_eligibility_ck CHECK (eligibility_state IN ('ELIGIBLE','TOMBSTONE'));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_publication_ck CHECK (publication_state IS NULL OR publication_state IN ('NEVER_PUBLISHED','PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED','CORRECTED','RETRACTED','TEMPORARILY_RESTRICTED'));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_publication_shape_ck CHECK (((object_type='CASE' AND publication_state IS NOT NULL) OR (object_type='CORRECTION' AND publication_state IS NOT NULL AND publication_state IN ('CORRECTED','RETRACTED')) OR (object_type NOT IN ('CASE','CORRECTION') AND publication_state IS NULL)));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_date_basis_ck CHECK ((object_type='CASE' AND search_date_basis='CASE_PUBLICATION') OR (object_type='CORRECTION' AND search_date_basis='CORRECTION_PUBLICATION') OR (object_type='CONTRACT' AND search_date_basis IN ('CONTRACT_SIGNED','OBJECT_UPDATED')) OR (object_type IN ('AGENCY','SUPPLIER','METHODOLOGY') AND search_date_basis='OBJECT_UPDATED'));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_alias_ck CHECK (cardinality(verified_aliases)=cardinality(normalized_verified_aliases) AND cardinality(verified_aliases)=cardinality(verified_alias_source_document_ids) AND ops.text_array_is_sorted_unique(normalized_verified_aliases) AND (object_type IN ('AGENCY','SUPPLIER') OR cardinality(verified_aliases)=0));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_title_ck CHECK (eligibility_state='TOMBSTONE' OR (coalesce(length(btrim(canonical_title)),0)>0 OR coalesce(length(btrim(canonical_name)),0)>0));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_href_ck CHECK (eligibility_state='TOMBSTONE' OR href LIKE '/%');
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_freshness_ck CHECK (freshness_status IN ('CURRENT','DELAYED','STALE','UNKNOWN') AND (expected_frequency_seconds IS NULL OR expected_frequency_seconds >= 0) AND (lag_seconds IS NULL OR lag_seconds >= 0));
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_policy_ck CHECK (ranking_policy_version='search-rank-v1');
REVOKE ALL ON public.search_documents FROM PUBLIC;
REVOKE ALL ON public.search_documents FROM gurine_workflow_worker;
REVOKE ALL ON public.search_documents FROM gurine_control_api;
REVOKE ALL ON public.search_documents FROM gurine_analysis_worker;
REVOKE ALL ON public.search_documents FROM gurine_public_projector;
REVOKE ALL ON public.search_documents FROM gurine_notification_worker;
REVOKE ALL ON public.search_documents FROM gurine_submission_api;
REVOKE ALL ON public.search_documents FROM gurine_auditor;
GRANT SELECT ON public.search_documents TO gurine_public_api;
CREATE TABLE ops.search_documents (
  projection_generation_id uuid NOT NULL,
  snapshot_kind text NOT NULL DEFAULT 'INTERNAL_SEARCH_PROJECTION',
  producer_generation bigint NOT NULL,
  projection_watermark bigint NOT NULL,
  snapshot_contract_version smallint NOT NULL,
  member_ordinal bigint NOT NULL,
  member_digest char(64) NOT NULL,
  document_watermark bigint NOT NULL,
  origin_kind text NOT NULL,
  source_event_id uuid,
  source_event_type text NOT NULL,
  source_event_version integer NOT NULL,
  source_object_sha256 char(64) NOT NULL,
  object_type text NOT NULL,
  object_type_order smallint NOT NULL,
  object_id uuid NOT NULL,
  object_revision bigint NOT NULL,
  eligibility_state text NOT NULL,
  status text NOT NULL,
  classification text NOT NULL,
  required_capabilities text[] NOT NULL,
  authorization_scope_type text NOT NULL,
  authorization_scope_id text,
  authorization_scope_sha256 char(64) NOT NULL,
  identifier_text text,
  normalized_identifier_key text,
  canonical_title text,
  canonical_name text,
  normalized_title text NOT NULL,
  verified_aliases text[] NOT NULL DEFAULT '{}'::text[],
  normalized_verified_aliases text[] NOT NULL DEFAULT '{}'::text[],
  authorized_summary text,
  authorized_body text,
  authorized_locator text,
  identifier_tokens text NOT NULL DEFAULT '',
  canonical_title_tokens text NOT NULL DEFAULT '',
  canonical_name_tokens text NOT NULL DEFAULT '',
  verified_alias_tokens text NOT NULL DEFAULT '',
  authorized_summary_tokens text NOT NULL DEFAULT '',
  authorized_body_tokens text NOT NULL DEFAULT '',
  locator_tokens text NOT NULL DEFAULT '',
  search_vector tsvector NOT NULL,
  href text NOT NULL,
  freshness_as_of timestamptz NOT NULL,
  last_successful_fetch_at timestamptz,
  expected_frequency_seconds bigint,
  lag_seconds bigint,
  freshness_status text NOT NULL,
  source_updated_at timestamptz NOT NULL,
  indexed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ranking_policy_version text NOT NULL DEFAULT 'search-rank-v1',
  normalizer_version text NOT NULL,
  normalizer_sha256 char(64) NOT NULL,
  document_digest char(64) NOT NULL,
  CONSTRAINT ops_search_documents_pk PRIMARY KEY (projection_generation_id, object_type, object_id, object_revision)
);
ALTER TABLE ops.search_documents OWNER TO gurine_migrator;
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_member_uk UNIQUE (projection_generation_id, member_ordinal);
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_member_digest_uk UNIQUE (projection_generation_id, member_digest);
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_object_uk UNIQUE (projection_generation_id, object_type, object_id);
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_event_object_uk UNIQUE (projection_generation_id, source_event_id, object_type, object_id, object_revision);
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_kind_ck CHECK (snapshot_kind='INTERNAL_SEARCH_PROJECTION');
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_type_ck CHECK (object_type IN ('CASE','SIGNAL','EVIDENCE','AGENT_RUN','AUDIT_EVENT'));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_type_order_ck CHECK ((object_type='CASE' AND object_type_order=1) OR (object_type='SIGNAL' AND object_type_order=2) OR (object_type='EVIDENCE' AND object_type_order=3) OR (object_type='AGENT_RUN' AND object_type_order=4) OR (object_type='AUDIT_EVENT' AND object_type_order=5));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_status_ck CHECK ((object_type='CASE' AND status IN ('SIGNAL_DETECTED','TRIAGE','INVESTIGATING','AWAITING_RESPONSE','EDITORIAL_REVIEW','LEGAL_REVIEW','READY_TO_PUBLISH','CLOSED')) OR (object_type='SIGNAL' AND status IN ('NEW','ASSIGNED','NEEDS_DATA','LINKED','DISMISSED','DUPLICATE')) OR (object_type='EVIDENCE' AND status IN ('PENDING','VERIFIED','REJECTED','NEEDS_WORK')) OR (object_type='AGENT_RUN' AND status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED')) OR (object_type='AUDIT_EVENT' AND status IN ('SUCCESS','DENIED','FAILED')));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_positive_ck CHECK (producer_generation > 0 AND projection_watermark >= 0 AND member_ordinal >= 0 AND document_watermark BETWEEN 0 AND projection_watermark AND source_event_version > 0 AND object_revision > 0);
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_origin_ck CHECK (origin_kind IN ('EVENT','DETERMINISTIC_BACKFILL') AND ((origin_kind='EVENT' AND source_event_id IS NOT NULL) OR (origin_kind='DETERMINISTIC_BACKFILL' AND source_event_id IS NULL AND document_watermark=projection_watermark)));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_eligibility_ck CHECK (eligibility_state IN ('ELIGIBLE','TOMBSTONE'));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_classification_ck CHECK (classification IN ('PUBLIC','INTERNAL','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD'));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_scope_ck CHECK (authorization_scope_type IN ('GLOBAL','CASE','OBJECT') AND ((authorization_scope_type='GLOBAL' AND authorization_scope_id IS NULL) OR (authorization_scope_type<>'GLOBAL' AND authorization_scope_id IS NOT NULL AND length(btrim(authorization_scope_id)) > 0)));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_capability_array_ck CHECK (ops.text_array_is_sorted_unique(required_capabilities) AND ops.text_array_is_sorted_unique(normalized_verified_aliases));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_type_capability_ck CHECK ((object_type='CASE' AND required_capabilities=ARRAY['cases.read']::text[]) OR (object_type='SIGNAL' AND required_capabilities=ARRAY['cases.read','signals.read']::text[]) OR (object_type='EVIDENCE' AND required_capabilities=ARRAY['cases.read']::text[]) OR (object_type='AGENT_RUN' AND required_capabilities=ARRAY['cases.read']::text[]) OR (object_type='AUDIT_EVENT' AND required_capabilities=ARRAY['audit.read']::text[]));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_title_ck CHECK (eligibility_state='TOMBSTONE' OR (coalesce(length(btrim(canonical_title)),0)>0 OR coalesce(length(btrim(canonical_name)),0)>0));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_href_ck CHECK (eligibility_state='TOMBSTONE' OR href LIKE '/internal/%');
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_freshness_ck CHECK (freshness_status IN ('CURRENT','DELAYED','STALE','UNKNOWN') AND (expected_frequency_seconds IS NULL OR expected_frequency_seconds >= 0) AND (lag_seconds IS NULL OR lag_seconds >= 0));
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_policy_ck CHECK (ranking_policy_version='search-rank-v1');
REVOKE ALL ON ops.search_documents FROM PUBLIC;
REVOKE ALL ON ops.search_documents FROM gurine_workflow_worker;
REVOKE ALL ON ops.search_documents FROM gurine_control_api;
REVOKE ALL ON ops.search_documents FROM gurine_analysis_worker;
REVOKE ALL ON ops.search_documents FROM gurine_public_projector;
REVOKE ALL ON ops.search_documents FROM gurine_notification_worker;
REVOKE ALL ON ops.search_documents FROM gurine_submission_api;
REVOKE ALL ON ops.search_documents FROM gurine_auditor;
GRANT SELECT ON ops.search_documents TO gurine_control_api;
CREATE TABLE raw.source_page_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  source_run_id uuid NOT NULL,
  expected_source_run_version bigint NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  connector_contract_version text NOT NULL,
  connector_contract_sha256 char(64) NOT NULL,
  operation_id text NOT NULL,
  partition_key text NOT NULL,
  window_start text,
  window_end text,
  window_sha256 char(64) NOT NULL,
  ordinal bigint NOT NULL,
  parent_page_receipt_id uuid,
  pagination_strategy text NOT NULL,
  upstream_page_number bigint,
  upstream_page_size integer,
  reported_total_pages bigint,
  expected_receipt_count bigint NOT NULL,
  manifest_sha256 char(64),
  position_kind text NOT NULL,
  position_value text NOT NULL,
  position_sha256 char(64) NOT NULL,
  next_position_kind text,
  next_position_value text,
  next_position_sha256 char(64),
  source_fetch_id uuid NOT NULL,
  request_sha256 char(64) NOT NULL,
  response_sha256 char(64) NOT NULL,
  item_count bigint NOT NULL,
  item_identity_digests text[] NOT NULL DEFAULT '{}'::text[],
  item_set_sha256 char(64) NOT NULL,
  parsed_item_count bigint NOT NULL,
  reconciled_item_count bigint NOT NULL,
  duplicate_item_count bigint NOT NULL,
  reported_total bigint,
  remote_identity_set_sha256 char(64) NOT NULL,
  remote_revision_set_sha256 char(64) NOT NULL,
  terminal_predicate_version text NOT NULL,
  terminal_predicate_sha256 char(64) NOT NULL,
  terminal_page boolean NOT NULL,
  terminal_evidence_sha256 char(64) NOT NULL,
  checkpoint_expected_version bigint NOT NULL,
  checkpoint_before_sha256 char(64) NOT NULL,
  checkpoint_candidate_sha256 char(64) NOT NULL,
  receipt_version bigint NOT NULL DEFAULT 1,
  receipt_digest char(64) NOT NULL,
  received_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT source_page_receipts_pk PRIMARY KEY (id)
);
ALTER TABLE raw.source_page_receipts OWNER TO gurine_migrator;
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_ordinal_uk UNIQUE (source_run_id, connector_id, operation_id, partition_key, ordinal);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_position_uk UNIQUE (source_run_id, connector_id, operation_id, partition_key, position_sha256);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_fetch_uk UNIQUE (source_fetch_id);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_digest_uk UNIQUE (receipt_digest);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_run_source_binding_uk UNIQUE (id, source_run_id, source_id);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_parent_binding_uk UNIQUE (id, source_run_id, connector_id, manifest_sha256, item_count);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_positive_ck CHECK (ordinal >= 0 AND expected_source_run_version > 0 AND expected_receipt_count > 0 AND item_count >= 0 AND parsed_item_count >= 0 AND reconciled_item_count >= 0 AND duplicate_item_count >= 0 AND checkpoint_expected_version > 0 AND receipt_version=1);
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_count_ck CHECK (parsed_item_count <= item_count AND reconciled_item_count <= parsed_item_count AND duplicate_item_count <= item_count AND (reported_total IS NULL OR reported_total >= 0));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_connector_operation_ck CHECK (ops.connector_operation_contract_is_valid(connector_id,operation_id,pagination_strategy,terminal_predicate_version,terminal_predicate_sha256,connector_contract_version,connector_contract_sha256));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_pagination_ck CHECK (pagination_strategy IN ('PAGE_NUMBER','NONE','MANIFEST_DOCUMENTS_ARRAY','MANIFEST_ORDER'));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_position_kind_ck CHECK (position_kind IN ('SINGLE','PAGE_NUMBER','MANIFEST_INDEX','DOCUMENT_KEY') AND (next_position_kind IS NULL OR next_position_kind IN ('PAGE_NUMBER','MANIFEST_INDEX','DOCUMENT_KEY')));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_item_set_ck CHECK (cardinality(item_identity_digests)=item_count AND (item_count=0 OR ops.digest_array_is_sorted_unique(item_identity_digests)));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_next_shape_ck CHECK ((next_position_kind IS NULL AND next_position_value IS NULL AND next_position_sha256 IS NULL) OR (next_position_kind IS NOT NULL AND next_position_value IS NOT NULL AND length(btrim(next_position_value)) > 0 AND next_position_sha256 IS NOT NULL));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_terminal_shape_ck CHECK (terminal_page=(ordinal=expected_receipt_count-1) AND ((terminal_page AND next_position_kind IS NULL) OR (NOT terminal_page AND next_position_kind IS NOT NULL)));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_page_number_ck CHECK (pagination_strategy<>'PAGE_NUMBER' OR (upstream_page_number IS NOT NULL AND upstream_page_number=ordinal+1 AND upstream_page_size IS NOT NULL AND upstream_page_size>0 AND reported_total IS NOT NULL AND reported_total_pages IS NOT NULL AND reported_total_pages=GREATEST(1,CEIL(reported_total::numeric/upstream_page_size::numeric))::bigint AND expected_receipt_count=reported_total_pages AND parent_page_receipt_id IS NULL AND manifest_sha256 IS NULL));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_none_ck CHECK (pagination_strategy<>'NONE' OR (ordinal=0 AND expected_receipt_count=1 AND terminal_page AND upstream_page_number IS NULL AND upstream_page_size IS NULL AND reported_total_pages IS NULL AND parent_page_receipt_id IS NULL AND manifest_sha256 IS NULL));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_manifest_root_ck CHECK (pagination_strategy<>'MANIFEST_DOCUMENTS_ARRAY' OR (ordinal=0 AND expected_receipt_count=1 AND terminal_page AND manifest_sha256 IS NOT NULL AND parent_page_receipt_id IS NULL));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_manifest_child_ck CHECK (pagination_strategy<>'MANIFEST_ORDER' OR (parent_page_receipt_id IS NOT NULL AND manifest_sha256 IS NOT NULL AND expected_receipt_count > 0 AND upstream_page_number IS NULL AND upstream_page_size IS NULL AND reported_total_pages IS NULL));
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_nonempty_ck CHECK (length(btrim(connector_id)) > 0 AND length(btrim(connector_contract_version)) > 0 AND length(btrim(operation_id)) > 0 AND length(btrim(partition_key)) > 0 AND length(btrim(position_value)) > 0 AND length(btrim(terminal_predicate_version)) > 0);
REVOKE ALL ON raw.source_page_receipts FROM PUBLIC;
REVOKE ALL ON raw.source_page_receipts FROM gurine_workflow_worker;
REVOKE ALL ON raw.source_page_receipts FROM gurine_control_api;
REVOKE ALL ON raw.source_page_receipts FROM gurine_analysis_worker;
REVOKE ALL ON raw.source_page_receipts FROM gurine_public_projector;
REVOKE ALL ON raw.source_page_receipts FROM gurine_notification_worker;
REVOKE ALL ON raw.source_page_receipts FROM gurine_submission_api;
REVOKE ALL ON raw.source_page_receipts FROM gurine_auditor;
GRANT SELECT, INSERT ON raw.source_page_receipts TO gurine_ingest_worker;
GRANT SELECT ON raw.source_page_receipts TO gurine_control_api;
CREATE TRIGGER raw_source_page_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON raw.source_page_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_notice_revisions (
  revision_id uuid NOT NULL,
  root_id uuid NOT NULL,
  revision bigint NOT NULL,
  record_digest char(64) NOT NULL,
  predecessor_revision_id uuid,
  predecessor_revision bigint,
  predecessor_record_digest char(64),
  supersedes_revision_id uuid,
  revision_state text NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  operation_id text NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  source_external_id text NOT NULL,
  source_external_revision text NOT NULL,
  parsed_record_id uuid NOT NULL,
  record_index integer NOT NULL,
  source_record_digest char(64) NOT NULL,
  retrieved_at timestamptz NOT NULL,
  mapping_version text NOT NULL,
  mapping_effective_from timestamptz NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  field_provenance_set_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  typed_payload jsonb NOT NULL,
  external_notice_id text NOT NULL,
  notice_number text NOT NULL,
  notice_order text NOT NULL,
  title text NOT NULL,
  business_type text NOT NULL,
  agency_id uuid NOT NULL,
  agency_revision bigint NOT NULL,
  agency_identity_digest char(64) NOT NULL,
  agency_snapshot_canonical bytea NOT NULL,
  procurement_method text,
  published_at timestamptz,
  closes_at timestamptz,
  estimated_amount numeric(24,6),
  estimated_currency char(3),
  cancellation_reason_digest char(64),
  specification_detail_set_digest char(64) NOT NULL,
  CONSTRAINT procurement_notice_revisions_pk PRIMARY KEY (revision_id)
);
ALTER TABLE core.procurement_notice_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_root_revision_uq UNIQUE (root_id, revision);
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_exact_revision_uq UNIQUE (root_id, revision_id, revision, record_digest);
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_record_digest_uq UNIQUE (record_digest);
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_source_revision_uq UNIQUE (connector_id, source_external_id, source_external_revision, mapping_version);
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_external_revision_uq UNIQUE (connector_id, external_notice_id, revision);
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_common_ck CHECK (revision > 0 AND source_asset_revision > 0 AND record_index >= 0 AND revision_state IN ('ACTIVE','CANCELLED','DELETED','SUPERSEDED','CORRECTED') AND coverage_status IN ('COMPLETE','PARTIAL','UNKNOWN','NOT_AVAILABLE'));
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_chain_ck CHECK ((revision=1 AND root_id=revision_id AND num_nonnulls(predecessor_revision_id,predecessor_revision,predecessor_record_digest,supersedes_revision_id)=0) OR (revision>1 AND root_id<>revision_id AND predecessor_revision=revision-1 AND predecessor_revision_id=supersedes_revision_id AND num_nonnulls(predecessor_revision_id,predecessor_revision,predecessor_record_digest,supersedes_revision_id)=4));
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_time_ck CHECK ((effective_time_status='UNKNOWN' AND num_nonnulls(effective_time_value,effective_time_precision,effective_time_source_field,effective_time_timezone)=0) OR (effective_time_status='KNOWN' AND effective_time_precision IN ('DATE','MINUTE','SECOND') AND num_nonnulls(effective_time_value,effective_time_precision,effective_time_source_field,effective_time_timezone)=4));
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_payload_ck CHECK (ops.procurement_notice_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND record_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_amount_ck CHECK ((estimated_amount IS NULL)=(estimated_currency IS NULL) AND (estimated_amount IS NULL OR (estimated_amount>=0 AND estimated_currency ~ '^[A-Z]{3}$')));
REVOKE ALL ON core.procurement_notice_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_notice_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_notice_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_notice_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_notice_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_notice_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_notice_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_notice_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_award_revisions (
  revision_id uuid NOT NULL,
  root_id uuid NOT NULL,
  revision bigint NOT NULL,
  record_digest char(64) NOT NULL,
  predecessor_revision_id uuid,
  predecessor_revision bigint,
  predecessor_record_digest char(64),
  supersedes_revision_id uuid,
  revision_state text NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  operation_id text NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  source_external_id text NOT NULL,
  source_external_revision text NOT NULL,
  parsed_record_id uuid NOT NULL,
  record_index integer NOT NULL,
  source_record_digest char(64) NOT NULL,
  retrieved_at timestamptz NOT NULL,
  mapping_version text NOT NULL,
  mapping_effective_from timestamptz NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  field_provenance_set_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  typed_payload jsonb NOT NULL,
  external_award_id text NOT NULL,
  notice_revision_id uuid NOT NULL,
  notice_root_id uuid NOT NULL,
  notice_revision bigint NOT NULL,
  notice_record_digest char(64) NOT NULL,
  award_basis text NOT NULL,
  awarded_at_value text,
  awarded_amount numeric(24,6),
  awarded_currency char(3),
  winner_count integer NOT NULL,
  winner_set_digest char(64) NOT NULL,
  CONSTRAINT procurement_award_revisions_pk PRIMARY KEY (revision_id)
);
ALTER TABLE core.procurement_award_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_root_revision_uq UNIQUE (root_id, revision);
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_exact_revision_uq UNIQUE (root_id, revision_id, revision, record_digest);
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_record_digest_uq UNIQUE (record_digest);
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_source_revision_uq UNIQUE (connector_id, source_external_id, source_external_revision, mapping_version);
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_shape_ck CHECK (revision>0 AND winner_count BETWEEN 1 AND 100 AND award_basis IN ('OFFICIAL_AWARD_RESULT','CONTRACT_CONCLUSION') AND (awarded_amount IS NULL)=(awarded_currency IS NULL) AND (awarded_amount IS NULL OR (awarded_amount>=0 AND awarded_currency ~ '^[A-Z]{3}$')));
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_payload_ck CHECK (ops.award_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND record_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_award_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_award_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_award_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_award_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_award_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_award_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_award_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_award_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_award_winner_revisions (
  award_revision_id uuid NOT NULL,
  award_root_id uuid NOT NULL,
  award_revision bigint NOT NULL,
  award_record_digest char(64) NOT NULL,
  winner_ordinal integer NOT NULL,
  candidate_id uuid NOT NULL,
  candidate_revision bigint NOT NULL,
  candidate_digest char(64) NOT NULL,
  canonical_supplier_id uuid,
  identity_status text NOT NULL,
  member_payload jsonb NOT NULL,
  member_canonical bytea NOT NULL,
  member_digest_preimage_canonical bytea NOT NULL,
  member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_award_winners_pk PRIMARY KEY (award_revision_id, winner_ordinal)
);
ALTER TABLE core.procurement_award_winner_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winner_candidate_uq UNIQUE (award_revision_id, candidate_id, candidate_revision);
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winner_digest_uq UNIQUE (award_revision_id, member_digest);
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winner_shape_ck CHECK (winner_ordinal>=0 AND candidate_revision>0 AND identity_status IN ('UNVERIFIED','CANDIDATE','VERIFIED','AMBIGUOUS','CONFLICTED','REJECTED'));
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winner_payload_ck CHECK (ops.supplier_party_ref_v1_is_valid(member_payload) AND convert_from(member_canonical,'UTF8')::jsonb=member_payload AND member_digest=encode(extensions.digest(member_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_award_winner_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_award_winner_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_award_winner_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_award_winner_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_award_winner_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_award_winner_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_award_winner_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_award_winner_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_bidder_participation_revisions (
  revision_id uuid NOT NULL,
  root_id uuid NOT NULL,
  revision bigint NOT NULL,
  record_digest char(64) NOT NULL,
  predecessor_revision_id uuid,
  predecessor_revision bigint,
  predecessor_record_digest char(64),
  supersedes_revision_id uuid,
  revision_state text NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  operation_id text NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  source_external_id text NOT NULL,
  source_external_revision text NOT NULL,
  parsed_record_id uuid NOT NULL,
  record_index integer NOT NULL,
  source_record_digest char(64) NOT NULL,
  retrieved_at timestamptz NOT NULL,
  mapping_version text NOT NULL,
  mapping_effective_from timestamptz NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  field_provenance_set_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  typed_payload jsonb NOT NULL,
  external_participation_id text NOT NULL,
  notice_revision_id uuid NOT NULL,
  notice_root_id uuid NOT NULL,
  notice_revision bigint NOT NULL,
  notice_record_digest char(64) NOT NULL,
  candidate_id uuid NOT NULL,
  candidate_revision bigint NOT NULL,
  candidate_digest char(64) NOT NULL,
  participation_status text NOT NULL,
  submitted_at timestamptz,
  bid_amount numeric(24,6),
  bid_currency char(3),
  rank integer,
  invalid_reason_digest char(64),
  CONSTRAINT procurement_bidder_participation_pk PRIMARY KEY (revision_id)
);
ALTER TABLE core.procurement_bidder_participation_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_root_revision_uq UNIQUE (root_id, revision);
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_exact_revision_uq UNIQUE (root_id, revision_id, revision, record_digest);
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_source_revision_uq UNIQUE (connector_id, source_external_id, source_external_revision, mapping_version);
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_shape_ck CHECK (participation_status IN ('SUBMITTED','VALID','INVALID','WITHDRAWN','AWARDED','NOT_AWARDED','UNKNOWN') AND (bid_amount IS NULL)=(bid_currency IS NULL) AND (bid_amount IS NULL OR (bid_amount>=0 AND bid_currency ~ '^[A-Z]{3}$')) AND (rank IS NULL OR rank>0));
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_payload_ck CHECK (ops.bidder_participation_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND record_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_bidder_participation_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_bidder_participation_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_bidder_participation_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_bidder_participation_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_bidder_participation_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_bidder_participation_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_bidder_participation_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_contract_revisions (
  revision_id uuid NOT NULL,
  root_id uuid NOT NULL,
  revision bigint NOT NULL,
  record_digest char(64) NOT NULL,
  predecessor_revision_id uuid,
  predecessor_revision bigint,
  predecessor_record_digest char(64),
  supersedes_revision_id uuid,
  revision_state text NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  operation_id text NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  source_external_id text NOT NULL,
  source_external_revision text NOT NULL,
  parsed_record_id uuid NOT NULL,
  record_index integer NOT NULL,
  source_record_digest char(64) NOT NULL,
  retrieved_at timestamptz NOT NULL,
  mapping_version text NOT NULL,
  mapping_effective_from timestamptz NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  field_provenance_set_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  typed_payload jsonb NOT NULL,
  external_contract_id text NOT NULL,
  contract_number text,
  title text NOT NULL,
  business_type text NOT NULL,
  agency_id uuid NOT NULL,
  agency_revision bigint NOT NULL,
  agency_identity_digest char(64) NOT NULL,
  agency_snapshot_canonical bytea NOT NULL,
  supplier_count integer NOT NULL,
  supplier_set_digest char(64) NOT NULL,
  notice_revision_id uuid,
  notice_root_id uuid,
  notice_revision bigint,
  notice_record_digest char(64),
  award_revision_id uuid,
  award_root_id uuid,
  award_revision bigint,
  award_record_digest char(64),
  contract_status text NOT NULL,
  procurement_method text,
  signed_at date,
  starts_at date,
  ends_at date,
  original_amount numeric(24,6),
  current_amount numeric(24,6),
  currency char(3) NOT NULL,
  CONSTRAINT procurement_contract_revisions_pk PRIMARY KEY (revision_id)
);
ALTER TABLE core.procurement_contract_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_root_revision_uq UNIQUE (root_id, revision);
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_exact_revision_uq UNIQUE (root_id, revision_id, revision, record_digest);
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_record_digest_uq UNIQUE (record_digest);
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_source_revision_uq UNIQUE (connector_id, source_external_id, source_external_revision, mapping_version);
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_external_revision_uq UNIQUE (connector_id, external_contract_id, revision);
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_shape_ck CHECK (supplier_count BETWEEN 0 AND 100 AND contract_status IN ('ANNOUNCED','AWARDED','ACTIVE','COMPLETED','CANCELLED','SUPERSEDED','UNKNOWN') AND currency ~ '^[A-Z]{3}$' AND (original_amount IS NULL OR original_amount>=0) AND (current_amount IS NULL OR current_amount>=0) AND (starts_at IS NULL OR ends_at IS NULL OR starts_at<=ends_at));
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_payload_ck CHECK (ops.procurement_contract_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND record_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_contract_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_contract_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_contract_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_contract_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_contract_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_contract_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_contract_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_contract_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_contract_supplier_revisions (
  contract_revision_id uuid NOT NULL,
  contract_root_id uuid NOT NULL,
  contract_revision bigint NOT NULL,
  contract_record_digest char(64) NOT NULL,
  supplier_ordinal integer NOT NULL,
  candidate_id uuid NOT NULL,
  candidate_revision bigint NOT NULL,
  candidate_digest char(64) NOT NULL,
  canonical_supplier_id uuid,
  identity_status text NOT NULL,
  member_payload jsonb NOT NULL,
  member_canonical bytea NOT NULL,
  member_digest_preimage_canonical bytea NOT NULL,
  member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_contract_suppliers_pk PRIMARY KEY (contract_revision_id, supplier_ordinal)
);
ALTER TABLE core.procurement_contract_supplier_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_supplier_candidate_uq UNIQUE (contract_revision_id, candidate_id, candidate_revision);
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_supplier_digest_uq UNIQUE (contract_revision_id, member_digest);
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_supplier_shape_ck CHECK (supplier_ordinal>=0 AND candidate_revision>0 AND identity_status IN ('UNVERIFIED','CANDIDATE','VERIFIED','AMBIGUOUS','CONFLICTED','REJECTED'));
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_supplier_payload_ck CHECK (ops.supplier_party_ref_v1_is_valid(member_payload) AND convert_from(member_canonical,'UTF8')::jsonb=member_payload AND member_digest=encode(extensions.digest(member_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_contract_supplier_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_contract_supplier_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_contract_supplier_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_contract_supplier_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_contract_supplier_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_contract_supplier_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_contract_supplier_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_contract_amendment_revisions (
  revision_id uuid NOT NULL,
  root_id uuid NOT NULL,
  revision bigint NOT NULL,
  record_digest char(64) NOT NULL,
  predecessor_revision_id uuid,
  predecessor_revision bigint,
  predecessor_record_digest char(64),
  supersedes_revision_id uuid,
  revision_state text NOT NULL,
  source_id text NOT NULL,
  connector_id text NOT NULL,
  operation_id text NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  source_external_id text NOT NULL,
  source_external_revision text NOT NULL,
  parsed_record_id uuid NOT NULL,
  record_index integer NOT NULL,
  source_record_digest char(64) NOT NULL,
  retrieved_at timestamptz NOT NULL,
  mapping_version text NOT NULL,
  mapping_effective_from timestamptz NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  field_provenance_set_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  typed_payload jsonb NOT NULL,
  external_amendment_id text NOT NULL,
  amendment_sequence bigint NOT NULL,
  before_contract_revision_id uuid NOT NULL,
  before_contract_root_id uuid NOT NULL,
  before_contract_revision bigint NOT NULL,
  before_contract_digest char(64) NOT NULL,
  after_contract_revision_id uuid NOT NULL,
  after_contract_root_id uuid NOT NULL,
  after_contract_revision bigint NOT NULL,
  after_contract_digest char(64) NOT NULL,
  amendment_kind text NOT NULL,
  changed_at timestamptz,
  previous_amount numeric(24,6),
  new_amount numeric(24,6),
  amount_currency char(3),
  previous_end_at date,
  new_end_at date,
  reason_digest char(64),
  history_coverage_status text NOT NULL,
  CONSTRAINT procurement_contract_amendments_pk PRIMARY KEY (revision_id)
);
ALTER TABLE core.procurement_contract_amendment_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_root_revision_uq UNIQUE (root_id, revision);
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_exact_revision_uq UNIQUE (root_id, revision_id, revision, record_digest);
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_source_revision_uq UNIQUE (connector_id, source_external_id, source_external_revision, mapping_version);
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_contract_sequence_uq UNIQUE (after_contract_root_id, amendment_sequence);
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_shape_ck CHECK (amendment_sequence>0 AND before_contract_root_id=after_contract_root_id AND after_contract_revision=before_contract_revision+1 AND amendment_sequence=after_contract_revision-1 AND amendment_kind IN ('AMOUNT','TERM','SCOPE','PARTY','METHOD','CANCELLATION','MULTIPLE','UNKNOWN') AND history_coverage_status IN ('COMPLETE','PARTIAL','UNKNOWN','NOT_AVAILABLE'));
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_amount_ck CHECK (num_nonnulls(previous_amount,new_amount,amount_currency) IN (0,3) AND (amount_currency IS NULL OR amount_currency ~ '^[A-Z]{3}$') AND (previous_amount IS NULL OR previous_amount>=0) AND (new_amount IS NULL OR new_amount>=0));
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_payload_ck CHECK (ops.contract_amendment_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND record_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_contract_amendment_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_contract_amendment_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_contract_amendment_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_contract_amendment_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_contract_amendment_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_contract_amendment_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_contract_amendment_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_contract_line_item_revisions (
  line_item_id uuid NOT NULL,
  line_item_root_id uuid NOT NULL,
  line_item_revision bigint NOT NULL,
  line_item_digest char(64) NOT NULL,
  predecessor_line_item_revision_id uuid,
  predecessor_line_item_revision bigint,
  predecessor_line_item_digest char(64),
  contract_revision_id uuid NOT NULL,
  contract_root_id uuid NOT NULL,
  contract_revision bigint NOT NULL,
  contract_record_digest char(64) NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  parsed_record_id uuid NOT NULL,
  source_record_digest char(64) NOT NULL,
  record_index integer NOT NULL,
  normalization_run_id uuid NOT NULL,
  effective_time_value text,
  effective_time_status text NOT NULL,
  effective_time_precision text,
  effective_time_source_field text,
  effective_time_timezone text,
  external_line_item_id text,
  line_ordinal integer NOT NULL,
  description text NOT NULL,
  category_code text,
  manufacturer text,
  model text,
  quantity numeric(24,6),
  source_unit text,
  normalized_quantity numeric(24,6),
  normalized_unit text,
  unit_conversion_factor numeric(30,12),
  unit_conversion_policy_version text,
  unit_conversion_policy_digest char(64),
  unit_conversion_evidence_digest char(64),
  currency char(3),
  unit_price numeric(24,6),
  total_price numeric(24,6),
  vat_basis text NOT NULL,
  vat_rate numeric(9,8),
  vat_amount numeric(24,6),
  shipping_amount numeric(24,6),
  installation_amount numeric(24,6),
  maintenance_amount numeric(24,6),
  warranty_months integer,
  bundle_state text NOT NULL,
  component_count integer NOT NULL,
  component_set_digest char(64) NOT NULL,
  source_locator_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  typed_payload jsonb NOT NULL,
  payload_canonical bytea NOT NULL,
  digest_preimage_canonical bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_contract_line_items_pk PRIMARY KEY (line_item_id, line_item_revision)
);
ALTER TABLE core.procurement_contract_line_item_revisions OWNER TO gurine_migrator;
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_exact_revision_uq UNIQUE (line_item_root_id, line_item_id, line_item_revision, line_item_digest);
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_revision_binding_uq UNIQUE (line_item_id, line_item_revision, line_item_digest);
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_contract_ordinal_uq UNIQUE (contract_revision_id, line_ordinal);
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_digest_uq UNIQUE (line_item_digest);
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_revision_ck CHECK (line_item_revision>0 AND line_ordinal>=0 AND source_asset_revision>0 AND record_index>=0 AND coverage_status IN ('COMPLETE','PARTIAL','UNKNOWN','NOT_AVAILABLE'));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_chain_ck CHECK ((line_item_revision=1 AND line_item_root_id=line_item_id AND num_nonnulls(predecessor_line_item_revision_id,predecessor_line_item_revision,predecessor_line_item_digest)=0) OR (line_item_revision>1 AND line_item_root_id<>line_item_id AND predecessor_line_item_revision=line_item_revision-1 AND num_nonnulls(predecessor_line_item_revision_id,predecessor_line_item_revision,predecessor_line_item_digest)=3));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_quantity_ck CHECK ((quantity IS NULL OR quantity>=0) AND (normalized_quantity IS NULL OR normalized_quantity>=0) AND (unit_conversion_factor IS NULL OR unit_conversion_factor>0) AND num_nonnulls(normalized_quantity,normalized_unit,unit_conversion_factor,unit_conversion_policy_version,unit_conversion_policy_digest,unit_conversion_evidence_digest) IN (0,6));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_amount_ck CHECK ((currency IS NULL AND num_nonnulls(unit_price,total_price,vat_amount,shipping_amount,installation_amount,maintenance_amount)=0) OR (currency ~ '^[A-Z]{3}$' AND (unit_price IS NULL OR unit_price>=0) AND (total_price IS NULL OR total_price>=0) AND (vat_amount IS NULL OR vat_amount>=0) AND (shipping_amount IS NULL OR shipping_amount>=0) AND (installation_amount IS NULL OR installation_amount>=0) AND (maintenance_amount IS NULL OR maintenance_amount>=0)));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_vat_ck CHECK (vat_basis IN ('INCLUDED','EXCLUDED','EXEMPT','UNKNOWN') AND (vat_rate IS NULL OR vat_rate BETWEEN 0 AND 1));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_bundle_ck CHECK ((bundle_state='NOT_BUNDLE' AND component_count=0) OR (bundle_state='COMPLETE' AND component_count BETWEEN 1 AND 1000) OR (bundle_state IN ('PARTIAL','UNKNOWN') AND component_count BETWEEN 0 AND 1000));
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_payload_ck CHECK (ops.procurement_contract_line_item_revision_v1_is_valid(typed_payload) AND convert_from(payload_canonical,'UTF8')::jsonb=typed_payload AND line_item_digest=encode(extensions.digest(digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM PUBLIC;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_control_api;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_public_projector;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_submission_api;
REVOKE ALL ON core.procurement_contract_line_item_revisions FROM gurine_auditor;
GRANT SELECT ON core.procurement_contract_line_item_revisions TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_contract_line_item_revisions TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_contract_line_item_revisions TO gurine_control_api;
GRANT SELECT ON core.procurement_contract_line_item_revisions TO gurine_auditor;
CREATE TRIGGER core_procurement_contract_line_item_revisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_contract_line_item_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_contract_line_item_components (
  line_item_id uuid NOT NULL,
  line_item_revision bigint NOT NULL,
  line_item_digest char(64) NOT NULL,
  component_ordinal integer NOT NULL,
  component_id uuid NOT NULL,
  component_revision bigint NOT NULL,
  description text NOT NULL,
  quantity numeric(24,6),
  normalized_unit text,
  allocated_amount numeric(24,6),
  currency char(3),
  source_locator_digest char(64) NOT NULL,
  coverage_status text NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  component_payload jsonb NOT NULL,
  component_canonical bytea NOT NULL,
  component_digest_preimage_canonical bytea NOT NULL,
  component_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_line_item_components_pk PRIMARY KEY (line_item_id, line_item_revision, component_ordinal)
);
ALTER TABLE core.procurement_contract_line_item_components OWNER TO gurine_migrator;
ALTER TABLE core.procurement_contract_line_item_components ADD CONSTRAINT procurement_line_item_component_identity_uq UNIQUE (line_item_id, line_item_revision, component_id, component_revision);
ALTER TABLE core.procurement_contract_line_item_components ADD CONSTRAINT procurement_line_item_component_digest_uq UNIQUE (line_item_id, line_item_revision, component_digest);
ALTER TABLE core.procurement_contract_line_item_components ADD CONSTRAINT procurement_line_item_component_shape_ck CHECK (component_ordinal>=0 AND component_revision>0 AND (quantity IS NULL OR quantity>=0) AND (allocated_amount IS NULL OR allocated_amount>=0) AND (allocated_amount IS NULL)=(currency IS NULL) AND (currency IS NULL OR currency ~ '^[A-Z]{3}$') AND coverage_status IN ('COMPLETE','PARTIAL','UNKNOWN','NOT_AVAILABLE'));
ALTER TABLE core.procurement_contract_line_item_components ADD CONSTRAINT procurement_line_item_component_payload_ck CHECK (ops.procurement_contract_line_item_component_v1_is_valid(component_payload) AND convert_from(component_canonical,'UTF8')::jsonb=component_payload AND component_digest=encode(extensions.digest(component_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.procurement_contract_line_item_components FROM PUBLIC;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_control_api;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_public_projector;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_submission_api;
REVOKE ALL ON core.procurement_contract_line_item_components FROM gurine_auditor;
GRANT SELECT ON core.procurement_contract_line_item_components TO gurine_ingest_worker;
GRANT SELECT ON core.procurement_contract_line_item_components TO gurine_analysis_worker;
GRANT SELECT ON core.procurement_contract_line_item_components TO gurine_control_api;
GRANT SELECT ON core.procurement_contract_line_item_components TO gurine_auditor;
CREATE TRIGGER core_procurement_contract_line_item_components_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_contract_line_item_components FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.supplier_identity_candidates (
  candidate_id uuid NOT NULL,
  candidate_revision bigint NOT NULL,
  candidate_digest char(64) NOT NULL,
  predecessor_candidate_revision bigint,
  predecessor_candidate_digest char(64),
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  parsed_record_id uuid NOT NULL,
  source_record_digest char(64) NOT NULL,
  record_index integer NOT NULL,
  mapping_version text NOT NULL,
  normalized_name text NOT NULL,
  name_source_locator_digest char(64) NOT NULL,
  identifier_count integer NOT NULL,
  identifier_set_digest char(64) NOT NULL,
  identity_status text NOT NULL,
  canonical_supplier_id uuid,
  resolution_decision_id uuid,
  resolution_decision_digest char(64),
  candidate_payload jsonb NOT NULL,
  candidate_canonical bytea NOT NULL,
  candidate_digest_preimage_canonical bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_identity_candidates_pk PRIMARY KEY (candidate_id, candidate_revision)
);
ALTER TABLE core.supplier_identity_candidates OWNER TO gurine_migrator;
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_exact_uq UNIQUE (candidate_id, candidate_revision, candidate_digest);
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_source_mapping_uq UNIQUE (source_document_id, parsed_record_id, record_index, mapping_version);
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_shape_ck CHECK (candidate_revision>0 AND source_asset_revision>0 AND record_index>=0 AND identifier_count BETWEEN 0 AND 32 AND identity_status IN ('UNVERIFIED','CANDIDATE','VERIFIED','AMBIGUOUS','CONFLICTED','REJECTED') AND ((candidate_revision=1 AND predecessor_candidate_revision IS NULL AND predecessor_candidate_digest IS NULL) OR (candidate_revision>1 AND predecessor_candidate_revision=candidate_revision-1 AND predecessor_candidate_digest IS NOT NULL)) AND (resolution_decision_id IS NULL)=(resolution_decision_digest IS NULL));
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_payload_ck CHECK (ops.supplier_identity_candidate_v1_is_valid(candidate_payload) AND convert_from(candidate_canonical,'UTF8')::jsonb=candidate_payload AND candidate_digest=encode(extensions.digest(candidate_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.supplier_identity_candidates FROM PUBLIC;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_workflow_worker;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_control_api;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_analysis_worker;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_public_projector;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_notification_worker;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_submission_api;
REVOKE ALL ON core.supplier_identity_candidates FROM gurine_auditor;
GRANT SELECT ON core.supplier_identity_candidates TO gurine_ingest_worker;
GRANT SELECT ON core.supplier_identity_candidates TO gurine_analysis_worker;
GRANT SELECT ON core.supplier_identity_candidates TO gurine_control_api;
GRANT SELECT ON core.supplier_identity_candidates TO gurine_auditor;
CREATE TRIGGER core_supplier_identity_candidates_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.supplier_identity_candidates FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.supplier_identity_resolution_decisions (
  decision_id uuid NOT NULL,
  decision_sequence bigint NOT NULL,
  action text NOT NULL,
  candidate_count integer NOT NULL,
  candidate_set_digest char(64) NOT NULL,
  from_supplier_ids_canonical bytea NOT NULL,
  from_supplier_set_digest char(64) NOT NULL,
  to_supplier_ids_canonical bytea NOT NULL,
  to_supplier_set_digest char(64) NOT NULL,
  evidence_locator_set_canonical bytea NOT NULL,
  evidence_locator_set_digest char(64) NOT NULL,
  prior_decision_id uuid,
  prior_decision_digest char(64),
  actor_user_id uuid NOT NULL,
  reason_code text NOT NULL,
  reason_digest char(64) NOT NULL,
  impact_assessment_task_id uuid,
  impact_owner_user_id uuid,
  impact_due_at timestamptz,
  affected_public_revision_ids_canonical bytea NOT NULL,
  affected_public_revision_set_digest char(64) NOT NULL,
  decision_payload jsonb NOT NULL,
  decision_canonical bytea NOT NULL,
  decision_digest_preimage_canonical bytea NOT NULL,
  decision_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_resolution_decisions_pk PRIMARY KEY (decision_id)
);
ALTER TABLE core.supplier_identity_resolution_decisions OWNER TO gurine_migrator;
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_sequence_uq UNIQUE (decision_sequence);
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_digest_uq UNIQUE (decision_digest);
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_exact_uq UNIQUE (decision_id, decision_digest);
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_outbox_uq UNIQUE (outbox_event_id);
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_shape_ck CHECK (decision_sequence>0 AND candidate_count BETWEEN 1 AND 1000 AND action IN ('MERGE','SPLIT','KEEP_SEPARATE','MARK_AMBIGUOUS') AND reason_code IN ('AUTHORITATIVE_IDENTIFIER_MATCH','AUTHORITATIVE_IDENTIFIER_CONFLICT','SOURCE_CORRECTION','FALSE_MERGE','INSUFFICIENT_EVIDENCE') AND (prior_decision_id IS NULL)=(prior_decision_digest IS NULL));
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_split_impact_ck CHECK ((action='SPLIT' AND num_nonnulls(impact_assessment_task_id,impact_owner_user_id,impact_due_at)=3) OR (action<>'SPLIT' AND num_nonnulls(impact_assessment_task_id,impact_owner_user_id,impact_due_at) IN (0,3)));
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_payload_ck CHECK (ops.supplier_identity_resolution_decision_v1_is_valid(decision_payload) AND convert_from(decision_canonical,'UTF8')::jsonb=decision_payload AND decision_digest=encode(extensions.digest(decision_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM PUBLIC;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_workflow_worker;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_control_api;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_analysis_worker;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_public_projector;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_notification_worker;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_submission_api;
REVOKE ALL ON core.supplier_identity_resolution_decisions FROM gurine_auditor;
GRANT SELECT ON core.supplier_identity_resolution_decisions TO gurine_identity_api;
GRANT SELECT ON core.supplier_identity_resolution_decisions TO gurine_analysis_worker;
GRANT SELECT ON core.supplier_identity_resolution_decisions TO gurine_control_api;
GRANT SELECT ON core.supplier_identity_resolution_decisions TO gurine_auditor;
CREATE TRIGGER core_supplier_identity_resolution_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.supplier_identity_resolution_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.supplier_identity_resolution_decision_members (
  decision_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  member_ordinal integer NOT NULL,
  candidate_id uuid NOT NULL,
  candidate_revision bigint NOT NULL,
  candidate_digest char(64) NOT NULL,
  member_canonical bytea NOT NULL,
  member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_resolution_members_pk PRIMARY KEY (decision_id, member_ordinal)
);
ALTER TABLE core.supplier_identity_resolution_decision_members OWNER TO gurine_migrator;
ALTER TABLE core.supplier_identity_resolution_decision_members ADD CONSTRAINT supplier_resolution_member_candidate_uq UNIQUE (decision_id, candidate_id, candidate_revision);
ALTER TABLE core.supplier_identity_resolution_decision_members ADD CONSTRAINT supplier_resolution_member_digest_uq UNIQUE (decision_id, member_digest);
ALTER TABLE core.supplier_identity_resolution_decision_members ADD CONSTRAINT supplier_resolution_member_shape_ck CHECK (member_ordinal>=0 AND candidate_revision>0 AND member_digest ~ '^[0-9a-f]{64}$');
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM PUBLIC;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_workflow_worker;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_control_api;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_analysis_worker;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_public_projector;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_notification_worker;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_submission_api;
REVOKE ALL ON core.supplier_identity_resolution_decision_members FROM gurine_auditor;
GRANT SELECT ON core.supplier_identity_resolution_decision_members TO gurine_identity_api;
GRANT SELECT ON core.supplier_identity_resolution_decision_members TO gurine_analysis_worker;
GRANT SELECT ON core.supplier_identity_resolution_decision_members TO gurine_control_api;
GRANT SELECT ON core.supplier_identity_resolution_decision_members TO gurine_auditor;
CREATE TRIGGER core_supplier_identity_resolution_decision_members_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.supplier_identity_resolution_decision_members FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.supplier_relationship_assertions (
  assertion_id uuid NOT NULL,
  assertion_revision bigint NOT NULL,
  assertion_digest char(64) NOT NULL,
  predecessor_assertion_revision bigint,
  predecessor_assertion_digest char(64),
  relationship_kind text NOT NULL,
  subject_candidate_id uuid,
  subject_candidate_revision bigint,
  subject_candidate_digest char(64),
  subject_identity_key_digest char(64) NOT NULL,
  object_candidate_id uuid,
  object_candidate_revision bigint,
  object_candidate_digest char(64),
  object_identity_key_digest char(64) NOT NULL,
  ownership_percent numeric(7,4),
  management_role text,
  valid_from date,
  valid_to date,
  validity_coverage_status text NOT NULL,
  verification_status text NOT NULL,
  evidence_count integer NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  counter_assertion_set_digest char(64) NOT NULL,
  verified_by uuid,
  verified_at timestamptz,
  verification_reason_digest char(64),
  public_use_status text NOT NULL,
  created_by uuid NOT NULL,
  assertion_payload jsonb NOT NULL,
  assertion_canonical bytea NOT NULL,
  assertion_digest_preimage_canonical bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_relationship_assertions_pk PRIMARY KEY (assertion_id, assertion_revision)
);
ALTER TABLE core.supplier_relationship_assertions OWNER TO gurine_migrator;
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_exact_uq UNIQUE (assertion_id, assertion_revision, assertion_digest);
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_digest_uq UNIQUE (assertion_digest);
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_shape_ck CHECK (assertion_revision>0 AND relationship_kind IN ('OWNERSHIP','BENEFICIAL_OWNERSHIP','CONTROL','MANAGEMENT_ROLE','LEGAL_REPRESENTATIVE','CONTRACTUAL_RELATIONSHIP') AND validity_coverage_status IN ('COMPLETE','PARTIAL','UNKNOWN','NOT_AVAILABLE') AND verification_status IN ('PENDING','VERIFIED','REJECTED','CONFLICTED','SUPERSEDED') AND public_use_status IN ('NOT_REVIEWED','APPROVED','DENIED') AND evidence_count BETWEEN 1 AND 1000);
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_candidate_shape_ck CHECK (num_nonnulls(subject_candidate_id,subject_candidate_revision,subject_candidate_digest) IN (0,3) AND num_nonnulls(object_candidate_id,object_candidate_revision,object_candidate_digest) IN (0,3) AND NOT (subject_identity_key_digest=object_identity_key_digest));
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_verification_ck CHECK ((verification_status='PENDING' AND num_nonnulls(verified_by,verified_at,verification_reason_digest)=0) OR (verification_status<>'PENDING' AND num_nonnulls(verified_by,verified_at,verification_reason_digest)=3));
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_business_ck CHECK ((ownership_percent IS NULL OR ownership_percent BETWEEN 0 AND 100) AND (valid_from IS NULL OR valid_to IS NULL OR valid_from<=valid_to));
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_payload_ck CHECK (ops.supplier_relationship_assertion_v1_is_valid(assertion_payload) AND convert_from(assertion_canonical,'UTF8')::jsonb=assertion_payload AND assertion_digest=encode(extensions.digest(assertion_digest_preimage_canonical,'sha256'),'hex'));
REVOKE ALL ON core.supplier_relationship_assertions FROM PUBLIC;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_workflow_worker;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_control_api;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_analysis_worker;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_public_projector;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_notification_worker;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_submission_api;
REVOKE ALL ON core.supplier_relationship_assertions FROM gurine_auditor;
GRANT SELECT ON core.supplier_relationship_assertions TO gurine_identity_api;
GRANT SELECT ON core.supplier_relationship_assertions TO gurine_analysis_worker;
GRANT SELECT ON core.supplier_relationship_assertions TO gurine_control_api;
GRANT SELECT ON core.supplier_relationship_assertions TO gurine_auditor;
CREATE TRIGGER core_supplier_relationship_assertions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.supplier_relationship_assertions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.supplier_relationship_assertion_evidence (
  assertion_id uuid NOT NULL,
  assertion_revision bigint NOT NULL,
  assertion_digest char(64) NOT NULL,
  evidence_ordinal integer NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_case_id uuid NOT NULL,
  review_snapshot_version bigint NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  evidence_id uuid NOT NULL,
  evidence_version bigint NOT NULL,
  evidence_digest char(64) NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  locator_digest char(64) NOT NULL,
  evidence_binding_canonical bytea NOT NULL,
  evidence_member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_assertion_evidence_pk PRIMARY KEY (assertion_id, assertion_revision, evidence_ordinal)
);
ALTER TABLE core.supplier_relationship_assertion_evidence OWNER TO gurine_migrator;
ALTER TABLE core.supplier_relationship_assertion_evidence ADD CONSTRAINT supplier_assertion_evidence_identity_uq UNIQUE (assertion_id, assertion_revision, evidence_id, evidence_version, evidence_digest);
ALTER TABLE core.supplier_relationship_assertion_evidence ADD CONSTRAINT supplier_assertion_evidence_digest_uq UNIQUE (assertion_id, assertion_revision, evidence_member_digest);
ALTER TABLE core.supplier_relationship_assertion_evidence ADD CONSTRAINT supplier_assertion_evidence_shape_ck CHECK (evidence_ordinal>=0 AND review_snapshot_version>0 AND evidence_version>0 AND source_asset_revision>0 AND evidence_digest ~ '^[0-9a-f]{64}$' AND locator_digest ~ '^[0-9a-f]{64}$');
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM PUBLIC;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_workflow_worker;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_control_api;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_analysis_worker;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_public_projector;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_notification_worker;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_submission_api;
REVOKE ALL ON core.supplier_relationship_assertion_evidence FROM gurine_auditor;
GRANT SELECT ON core.supplier_relationship_assertion_evidence TO gurine_identity_api;
GRANT SELECT ON core.supplier_relationship_assertion_evidence TO gurine_analysis_worker;
GRANT SELECT ON core.supplier_relationship_assertion_evidence TO gurine_control_api;
GRANT SELECT ON core.supplier_relationship_assertion_evidence TO gurine_auditor;
CREATE TRIGGER core_supplier_relationship_assertion_evidence_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.supplier_relationship_assertion_evidence FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_query_snapshots (
  snapshot_id uuid NOT NULL,
  dataset_id text NOT NULL,
  filter_payload jsonb NOT NULL,
  filter_canonical bytea NOT NULL,
  filter_digest_preimage_canonical bytea NOT NULL,
  filter_digest char(64) NOT NULL,
  projection_generation_id uuid NOT NULL,
  projection_generation_version bigint NOT NULL,
  projection_generation_digest char(64) NOT NULL,
  projection_watermark bigint NOT NULL,
  visibility_as_of timestamptz NOT NULL,
  member_count bigint NOT NULL,
  member_set_digest char(64) NOT NULL,
  expires_at timestamptz NOT NULL,
  snapshot_payload jsonb NOT NULL,
  snapshot_canonical bytea NOT NULL,
  snapshot_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_query_snapshots_pk PRIMARY KEY (snapshot_id)
);
ALTER TABLE core.procurement_query_snapshots OWNER TO gurine_migrator;
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_digest_uq UNIQUE (snapshot_digest);
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_filter_binding_uq UNIQUE (snapshot_id, filter_digest, member_set_digest);
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_member_parent_uq UNIQUE (snapshot_id, member_count, member_set_digest);
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_shape_ck CHECK (dataset_id='PUBLIC_CONTRACTS' AND projection_generation_version>0 AND projection_watermark>=0 AND member_count>=0 AND expires_at>visibility_as_of AND visibility_as_of<=created_at);
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_payload_ck CHECK (ops.procurement_contract_filter_v1_is_valid(filter_payload) AND convert_from(filter_canonical,'UTF8')::jsonb=filter_payload AND filter_digest=encode(extensions.digest(filter_digest_preimage_canonical,'sha256'),'hex') AND ops.procurement_query_snapshot_v1_is_valid(snapshot_payload) AND convert_from(snapshot_canonical,'UTF8')::jsonb=snapshot_payload);
REVOKE ALL ON core.procurement_query_snapshots FROM PUBLIC;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_control_api;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_public_projector;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_submission_api;
REVOKE ALL ON core.procurement_query_snapshots FROM gurine_auditor;
GRANT SELECT ON core.procurement_query_snapshots TO gurine_control_api;
GRANT SELECT ON core.procurement_query_snapshots TO gurine_auditor;
CREATE TRIGGER core_procurement_query_snapshots_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_query_snapshots FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE core.procurement_query_snapshot_members (
  snapshot_id uuid NOT NULL,
  snapshot_member_count bigint NOT NULL,
  snapshot_member_set_digest char(64) NOT NULL,
  member_ordinal bigint NOT NULL,
  member_kind text NOT NULL,
  contract_revision_id uuid,
  contract_root_id uuid,
  contract_revision bigint,
  contract_record_digest char(64),
  line_item_id uuid,
  line_item_revision bigint,
  line_item_digest char(64),
  member_binding_canonical bytea NOT NULL,
  member_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT procurement_query_snapshot_members_pk PRIMARY KEY (snapshot_id, member_ordinal)
);
ALTER TABLE core.procurement_query_snapshot_members OWNER TO gurine_migrator;
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_member_digest_uq UNIQUE (snapshot_id, member_digest);
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_contract_uq UNIQUE (snapshot_id, contract_revision_id, line_item_id);
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_member_shape_ck CHECK (member_ordinal>=0 AND ((member_kind='CONTRACT' AND num_nonnulls(contract_revision_id,contract_root_id,contract_revision,contract_record_digest)=4 AND num_nonnulls(line_item_id,line_item_revision,line_item_digest)=0) OR (member_kind='CONTRACT_LINE_ITEM' AND num_nonnulls(contract_revision_id,contract_root_id,contract_revision,contract_record_digest,line_item_id,line_item_revision,line_item_digest)=7)));
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_member_digest_ck CHECK (member_digest ~ '^[0-9a-f]{64}$' AND contract_record_digest ~ '^[0-9a-f]{64}$' AND (line_item_digest IS NULL OR line_item_digest ~ '^[0-9a-f]{64}$'));
REVOKE ALL ON core.procurement_query_snapshot_members FROM PUBLIC;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_workflow_worker;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_control_api;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_analysis_worker;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_public_projector;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_notification_worker;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_submission_api;
REVOKE ALL ON core.procurement_query_snapshot_members FROM gurine_auditor;
GRANT SELECT ON core.procurement_query_snapshot_members TO gurine_control_api;
GRANT SELECT ON core.procurement_query_snapshot_members TO gurine_auditor;
CREATE TRIGGER core_procurement_query_snapshot_members_immutable_mutation_guard BEFORE UPDATE OR DELETE ON core.procurement_query_snapshot_members FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.response_request_claim_scopes (
  response_request_id uuid NOT NULL,
  response_request_version bigint NOT NULL,
  scope_version bigint NOT NULL,
  scope_digest char(64) NOT NULL,
  claim_ordinal integer NOT NULL,
  case_id uuid NOT NULL,
  claim_id uuid NOT NULL,
  claim_revision bigint NOT NULL,
  claim_digest char(64) NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_snapshot_version bigint NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  public_candidate_revision bigint NOT NULL,
  publication_revision bigint,
  requested_response_role text NOT NULL,
  evidence_locator_count integer NOT NULL,
  evidence_locator_set_digest char(64) NOT NULL,
  scope_header_payload jsonb,
  scope_header_canonical bytea,
  scope_digest_preimage_canonical bytea,
  claim_binding_canonical bytea NOT NULL,
  claim_binding_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_request_claim_scopes_pk PRIMARY KEY (response_request_id, scope_version, claim_ordinal)
);
ALTER TABLE editorial.response_request_claim_scopes OWNER TO gurine_migrator;
ALTER TABLE editorial.response_request_claim_scopes ADD CONSTRAINT response_request_claim_scope_exact_uq UNIQUE (response_request_id, scope_version, claim_ordinal, claim_binding_digest);
ALTER TABLE editorial.response_request_claim_scopes ADD CONSTRAINT response_request_claim_scope_claim_uq UNIQUE (response_request_id, scope_version, claim_id, claim_revision, claim_digest);
ALTER TABLE editorial.response_request_claim_scopes ADD CONSTRAINT response_request_claim_scope_header_uq UNIQUE (response_request_id, scope_version, scope_digest, claim_ordinal);
ALTER TABLE editorial.response_request_claim_scopes ADD CONSTRAINT response_request_claim_scope_shape_ck CHECK (response_request_version>0 AND scope_version>0 AND claim_ordinal>=0 AND claim_revision>0 AND review_snapshot_version>0 AND public_candidate_revision>0 AND evidence_locator_count BETWEEN 1 AND 1000 AND requested_response_role IN ('CONFIRM','DISPUTE','EXPLAIN','PROVIDE_MISSING_INFORMATION'));
ALTER TABLE editorial.response_request_claim_scopes ADD CONSTRAINT response_request_claim_scope_header_ck CHECK ((claim_ordinal=0 AND num_nonnulls(scope_header_payload,scope_header_canonical,scope_digest_preimage_canonical)=3 AND ops.response_request_scope_v1_is_valid(scope_header_payload) AND convert_from(scope_header_canonical,'UTF8')::jsonb=scope_header_payload AND scope_digest=encode(extensions.digest(scope_digest_preimage_canonical,'sha256'),'hex')) OR (claim_ordinal>0 AND num_nonnulls(scope_header_payload,scope_header_canonical,scope_digest_preimage_canonical)=0));
REVOKE ALL ON editorial.response_request_claim_scopes FROM PUBLIC;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_workflow_worker;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_control_api;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_analysis_worker;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_public_projector;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_notification_worker;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_submission_api;
REVOKE ALL ON editorial.response_request_claim_scopes FROM gurine_auditor;
GRANT SELECT ON editorial.response_request_claim_scopes TO gurine_control_api;
GRANT SELECT ON editorial.response_request_claim_scopes TO gurine_workflow_worker;
GRANT SELECT ON editorial.response_request_claim_scopes TO gurine_notification_worker;
GRANT SELECT ON editorial.response_request_claim_scopes TO gurine_auditor;
CREATE TRIGGER editorial_response_request_claim_scopes_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.response_request_claim_scopes FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.response_request_evidence_scopes (
  response_request_id uuid NOT NULL,
  scope_version bigint NOT NULL,
  claim_ordinal integer NOT NULL,
  claim_binding_digest char(64) NOT NULL,
  evidence_ordinal integer NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_case_id uuid NOT NULL,
  review_snapshot_version bigint NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  evidence_id uuid NOT NULL,
  evidence_version bigint NOT NULL,
  evidence_digest char(64) NOT NULL,
  source_document_id uuid NOT NULL,
  source_asset_id uuid NOT NULL,
  source_asset_revision bigint NOT NULL,
  source_content_sha256 char(64) NOT NULL,
  locator_payload jsonb NOT NULL,
  locator_canonical bytea NOT NULL,
  locator_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_request_evidence_scopes_pk PRIMARY KEY (response_request_id, scope_version, claim_ordinal, evidence_ordinal)
);
ALTER TABLE editorial.response_request_evidence_scopes OWNER TO gurine_migrator;
ALTER TABLE editorial.response_request_evidence_scopes ADD CONSTRAINT response_request_evidence_scope_evidence_uq UNIQUE (response_request_id, scope_version, claim_ordinal, evidence_id, evidence_version, evidence_digest, locator_digest);
ALTER TABLE editorial.response_request_evidence_scopes ADD CONSTRAINT response_request_evidence_scope_locator_uq UNIQUE (response_request_id, scope_version, claim_ordinal, locator_digest);
ALTER TABLE editorial.response_request_evidence_scopes ADD CONSTRAINT response_request_evidence_scope_shape_ck CHECK (scope_version>0 AND claim_ordinal>=0 AND evidence_ordinal>=0 AND review_snapshot_version>0 AND evidence_version>0 AND source_asset_revision>0);
ALTER TABLE editorial.response_request_evidence_scopes ADD CONSTRAINT response_request_evidence_scope_payload_ck CHECK (ops.ordered_evidence_locator_ref_v1_is_valid(locator_payload) AND convert_from(locator_canonical,'UTF8')::jsonb=locator_payload AND locator_digest=encode(extensions.digest(locator_canonical,'sha256'),'hex'));
REVOKE ALL ON editorial.response_request_evidence_scopes FROM PUBLIC;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_workflow_worker;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_control_api;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_analysis_worker;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_public_projector;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_notification_worker;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_submission_api;
REVOKE ALL ON editorial.response_request_evidence_scopes FROM gurine_auditor;
GRANT SELECT ON editorial.response_request_evidence_scopes TO gurine_control_api;
GRANT SELECT ON editorial.response_request_evidence_scopes TO gurine_workflow_worker;
GRANT SELECT ON editorial.response_request_evidence_scopes TO gurine_notification_worker;
GRANT SELECT ON editorial.response_request_evidence_scopes TO gurine_auditor;
CREATE TRIGGER editorial_response_request_evidence_scopes_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.response_request_evidence_scopes FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE OR REPLACE VIEW public.search_generations WITH (security_barrier = true) AS SELECT id, producer_generation, projection_watermark, contract_version, snapshot_sha256, member_count, member_set_sha256, ready_at FROM core.dataset_snapshots WHERE snapshot_kind='PUBLIC_SEARCH_PROJECTION' AND state='READY';
ALTER VIEW public.search_generations OWNER TO gurine_migrator;
REVOKE ALL ON public.search_generations FROM PUBLIC;
GRANT SELECT ON public.search_generations TO gurine_public_api;
ALTER TABLE core.dataset_snapshots ADD CONSTRAINT dataset_snapshots_prior_fk FOREIGN KEY (prior_snapshot_id, snapshot_kind, prior_snapshot_sha256) REFERENCES core.dataset_snapshots (id, snapshot_kind, snapshot_sha256) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_header_fk FOREIGN KEY (dataset_snapshot_id, snapshot_kind, producer_generation, snapshot_contract_version) REFERENCES core.dataset_snapshots (id, snapshot_kind, producer_generation, contract_version) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_normalization_fk FOREIGN KEY (normalization_run_id) REFERENCES core.normalization_runs (id) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_members ADD CONSTRAINT dataset_snapshot_members_evidence_fk FOREIGN KEY (evidence_segment_id, object_content_sha256) REFERENCES raw.evidence_segments (id, selected_content_sha256) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_member_fk FOREIGN KEY (snapshot_member_id, dataset_snapshot_id, member_ordinal, snapshot_member_digest) REFERENCES core.dataset_snapshot_members (id, dataset_snapshot_id, member_ordinal, member_digest) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id) REFERENCES core.normalization_runs (id, source_document_id) ON DELETE RESTRICT;
ALTER TABLE core.dataset_snapshot_member_sources ADD CONSTRAINT dataset_snapshot_member_sources_segment_fk FOREIGN KEY (evidence_segment_id, source_document_id, locator_digest) REFERENCES raw.evidence_segments (id, source_document_id, locator_digest) ON DELETE RESTRICT;
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_turn_fk FOREIGN KEY (agent_run_id, provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_turn_fk FOREIGN KEY (agent_run_id, provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_tool_fk FOREIGN KEY (agent_run_id, tool_call_id) REFERENCES ops.agent_tool_calls (agent_run_id, tool_call_id) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifacts ADD CONSTRAINT research_artifacts_call_fk FOREIGN KEY (agent_run_id, call_id, request_sha256, result_sha256) REFERENCES ops.agent_tool_calls (agent_run_id, call_id, request_sha256, result_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_output_validations ADD CONSTRAINT agent_output_validations_turn_fk FOREIGN KEY (agent_run_id, provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_validation_fk FOREIGN KEY (validation_id) REFERENCES ops.agent_output_validations (validation_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_member_fk FOREIGN KEY (snapshot_member_id, dataset_snapshot_id, snapshot_member_digest) REFERENCES core.dataset_snapshot_members (id, dataset_snapshot_id, member_digest) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_segment_fk FOREIGN KEY (evidence_segment_id, locator_digest, content_sha256) REFERENCES raw.evidence_segments (id, locator_digest, selected_content_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_artifact_fk FOREIGN KEY (research_artifact_id, agent_run_id, content_sha256) REFERENCES raw.research_artifacts (id, agent_run_id, content_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_source_use_fk FOREIGN KEY (agent_run_id, source_use_id, source_use_sha256) REFERENCES ops.agent_source_uses (agent_run_id, source_use_id, source_use_sha256) ON DELETE RESTRICT;
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_artifact_fk FOREIGN KEY (research_artifact_id, asset_id, asset_revision, asset_sha256) REFERENCES raw.research_artifacts (id, asset_id, asset_revision, content_sha256) ON DELETE RESTRICT;
ALTER TABLE raw.asset_rights_decisions ADD CONSTRAINT asset_rights_prior_fk FOREIGN KEY (prior_decision_id, asset_id, asset_revision, asset_sha256, prior_decision_version, prior_decision_sha256) REFERENCES raw.asset_rights_decisions (id, asset_id, asset_revision, asset_sha256, decision_version, decision_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_turn_fk FOREIGN KEY (agent_run_id, provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_tool_fk FOREIGN KEY (agent_run_id, tool_call_id) REFERENCES ops.agent_tool_calls (agent_run_id, tool_call_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_reconciliation_evidence ADD CONSTRAINT agent_reconciliation_evidence_provider_receipt_fk FOREIGN KEY (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_turn_fk FOREIGN KEY (agent_run_id, affected_provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_tool_fk FOREIGN KEY (agent_run_id, affected_tool_call_id) REFERENCES ops.agent_tool_calls (agent_run_id, tool_call_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_reconciliation_fk FOREIGN KEY (agent_run_id, reconciliation_evidence_id, reconciliation_evidence_sha256) REFERENCES ops.agent_reconciliation_evidence (agent_run_id, evidence_id, evidence_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_run_control_receipts ADD CONSTRAINT agent_run_control_receipts_prior_fk FOREIGN KEY (agent_run_id, prior_receipt_id, prior_receipt_sha256) REFERENCES ops.agent_run_control_receipts (agent_run_id, receipt_id, receipt_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_turn_fk FOREIGN KEY (agent_run_id, provider_turn_id) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_tool_fk FOREIGN KEY (agent_run_id, tool_call_id) REFERENCES ops.agent_tool_calls (agent_run_id, tool_call_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_parent_fk FOREIGN KEY (agent_run_id, parent_source_use_id, parent_source_use_sha256) REFERENCES ops.agent_source_uses (agent_run_id, source_use_id, source_use_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_promotion_fk FOREIGN KEY (promotion_id, promotion_receipt_sha256) REFERENCES raw.research_artifact_promotions (promotion_id, receipt_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_member_fk FOREIGN KEY (snapshot_member_id, dataset_snapshot_id, snapshot_member_digest, object_type, object_id, object_version, object_content_sha256) REFERENCES core.dataset_snapshot_members (id, dataset_snapshot_id, member_digest, object_type, object_id, object_version, object_content_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_member_document_fk FOREIGN KEY (snapshot_member_source_id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, snapshot_member_source_digest) REFERENCES core.dataset_snapshot_member_sources (id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, source_digest) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_member_response_fk FOREIGN KEY (snapshot_member_source_id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, response_id, response_version, response_content_sha256, snapshot_member_source_digest) REFERENCES core.dataset_snapshot_member_sources (id, dataset_snapshot_id, snapshot_member_id, snapshot_member_digest, response_id, response_version, response_content_sha256, source_digest) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_segment_fk FOREIGN KEY (evidence_segment_id, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, selected_content_sha256, locator_sha256) REFERENCES raw.evidence_segments (id, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, selected_content_sha256, locator_digest) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_artifact_fk FOREIGN KEY (research_artifact_id, research_asset_id, research_asset_revision, research_artifact_sha256, research_content_sha256, research_source_fetch_id) REFERENCES raw.research_artifacts (id, asset_id, asset_revision, artifact_sha256, content_sha256, source_fetch_id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_rights_fk FOREIGN KEY (asset_rights_decision_id, rights_asset_id, rights_asset_revision, rights_asset_sha256, asset_rights_decision_version, asset_rights_decision_sha256) REFERENCES raw.asset_rights_decisions (id, asset_id, asset_revision, asset_sha256, decision_version, decision_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_provider_receipt_fk FOREIGN KEY (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256) REFERENCES ops.agent_provider_turns (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_artifact_fk FOREIGN KEY (research_artifact_id, research_asset_id, research_asset_revision, research_artifact_sha256, research_content_sha256, research_source_fetch_id) REFERENCES raw.research_artifacts (id, asset_id, asset_revision, artifact_sha256, content_sha256, source_fetch_id) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_segment_fk FOREIGN KEY (primary_evidence_segment_id, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, primary_selected_content_sha256, primary_locator_sha256) REFERENCES raw.evidence_segments (id, source_document_id, source_asset_id, source_asset_revision, source_content_sha256, selected_content_sha256, locator_digest) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_rights_fk FOREIGN KEY (rights_decision_id, research_asset_id, research_asset_revision, research_content_sha256, rights_decision_version, rights_decision_sha256) REFERENCES raw.asset_rights_decisions (id, asset_id, asset_revision, asset_sha256, decision_version, decision_sha256) ON DELETE RESTRICT;
ALTER TABLE raw.research_artifact_promotions ADD CONSTRAINT research_artifact_promotions_source_use_fk FOREIGN KEY (agent_run_id, root_source_use_id, root_source_use_sha256) REFERENCES ops.agent_source_uses (agent_run_id, source_use_id, source_use_sha256) ON DELETE RESTRICT;
ALTER TABLE public.search_documents ADD CONSTRAINT public_search_documents_generation_fk FOREIGN KEY (projection_generation_id, snapshot_kind, producer_generation, projection_watermark, snapshot_contract_version) REFERENCES core.dataset_snapshots (id, snapshot_kind, producer_generation, projection_watermark, contract_version) ON DELETE RESTRICT;
ALTER TABLE ops.search_documents ADD CONSTRAINT ops_search_documents_generation_fk FOREIGN KEY (projection_generation_id, snapshot_kind, producer_generation, projection_watermark, snapshot_contract_version) REFERENCES core.dataset_snapshots (id, snapshot_kind, producer_generation, projection_watermark, contract_version) ON DELETE RESTRICT;
ALTER TABLE raw.source_page_receipts ADD CONSTRAINT source_page_receipts_parent_fk FOREIGN KEY (parent_page_receipt_id, source_run_id, connector_id, manifest_sha256, expected_receipt_count) REFERENCES raw.source_page_receipts (id, source_run_id, connector_id, manifest_sha256, item_count) ON DELETE RESTRICT;
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, revision_id, revision, record_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_notice_revisions ADD CONSTRAINT procurement_notice_predecessor_fk FOREIGN KEY (root_id, predecessor_revision_id, predecessor_revision, predecessor_record_digest) REFERENCES core.procurement_notice_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, revision_id, revision, record_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_predecessor_fk FOREIGN KEY (root_id, predecessor_revision_id, predecessor_revision, predecessor_record_digest) REFERENCES core.procurement_award_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_award_revisions ADD CONSTRAINT procurement_award_notice_fk FOREIGN KEY (notice_root_id, notice_revision_id, notice_revision, notice_record_digest) REFERENCES core.procurement_notice_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winners_parent_fk FOREIGN KEY (award_root_id, award_revision_id, award_revision, award_record_digest) REFERENCES core.procurement_award_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_award_winner_revisions ADD CONSTRAINT procurement_award_winners_candidate_fk FOREIGN KEY (candidate_id, candidate_revision, candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, revision_id, revision, record_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_predecessor_fk FOREIGN KEY (root_id, predecessor_revision_id, predecessor_revision, predecessor_record_digest) REFERENCES core.procurement_bidder_participation_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_notice_fk FOREIGN KEY (notice_root_id, notice_revision_id, notice_revision, notice_record_digest) REFERENCES core.procurement_notice_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_bidder_participation_revisions ADD CONSTRAINT procurement_bidder_candidate_fk FOREIGN KEY (candidate_id, candidate_revision, candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, revision_id, revision, record_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_predecessor_fk FOREIGN KEY (root_id, predecessor_revision_id, predecessor_revision, predecessor_record_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_notice_fk FOREIGN KEY (notice_root_id, notice_revision_id, notice_revision, notice_record_digest) REFERENCES core.procurement_notice_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_revisions ADD CONSTRAINT procurement_contract_award_fk FOREIGN KEY (award_root_id, award_revision_id, award_revision, award_record_digest) REFERENCES core.procurement_award_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_suppliers_parent_fk FOREIGN KEY (contract_root_id, contract_revision_id, contract_revision, contract_record_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_supplier_revisions ADD CONSTRAINT procurement_contract_suppliers_candidate_fk FOREIGN KEY (candidate_id, candidate_revision, candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, revision_id, revision, record_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_predecessor_fk FOREIGN KEY (root_id, predecessor_revision_id, predecessor_revision, predecessor_record_digest) REFERENCES core.procurement_contract_amendment_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_before_fk FOREIGN KEY (before_contract_root_id, before_contract_revision_id, before_contract_revision, before_contract_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_amendment_revisions ADD CONSTRAINT procurement_amendment_after_fk FOREIGN KEY (after_contract_root_id, after_contract_revision_id, after_contract_revision, after_contract_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_contract_fk FOREIGN KEY (contract_root_id, contract_revision_id, contract_revision, contract_record_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_normalization_fk FOREIGN KEY (normalization_run_id, source_document_id, line_item_id, line_item_revision, line_item_digest) REFERENCES core.normalization_runs (id, source_document_id, output_object_id, output_object_version, output_payload_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_line_item_revisions ADD CONSTRAINT procurement_line_item_predecessor_fk FOREIGN KEY (line_item_root_id, predecessor_line_item_revision_id, predecessor_line_item_revision, predecessor_line_item_digest) REFERENCES core.procurement_contract_line_item_revisions (line_item_root_id, line_item_id, line_item_revision, line_item_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_contract_line_item_components ADD CONSTRAINT procurement_line_item_components_parent_fk FOREIGN KEY (line_item_id, line_item_revision, line_item_digest) REFERENCES core.procurement_contract_line_item_revisions (line_item_id, line_item_revision, line_item_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_predecessor_fk FOREIGN KEY (candidate_id, predecessor_candidate_revision, predecessor_candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_identity_candidates ADD CONSTRAINT supplier_candidate_resolution_fk FOREIGN KEY (resolution_decision_id, resolution_decision_digest) REFERENCES core.supplier_identity_resolution_decisions (decision_id, decision_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_identity_resolution_decisions ADD CONSTRAINT supplier_resolution_prior_fk FOREIGN KEY (prior_decision_id, prior_decision_digest) REFERENCES core.supplier_identity_resolution_decisions (decision_id, decision_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_identity_resolution_decision_members ADD CONSTRAINT supplier_resolution_members_parent_fk FOREIGN KEY (decision_id, decision_digest) REFERENCES core.supplier_identity_resolution_decisions (decision_id, decision_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_identity_resolution_decision_members ADD CONSTRAINT supplier_resolution_members_candidate_fk FOREIGN KEY (candidate_id, candidate_revision, candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_predecessor_fk FOREIGN KEY (assertion_id, predecessor_assertion_revision, predecessor_assertion_digest) REFERENCES core.supplier_relationship_assertions (assertion_id, assertion_revision, assertion_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_subject_candidate_fk FOREIGN KEY (subject_candidate_id, subject_candidate_revision, subject_candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_relationship_assertions ADD CONSTRAINT supplier_assertion_object_candidate_fk FOREIGN KEY (object_candidate_id, object_candidate_revision, object_candidate_digest) REFERENCES core.supplier_identity_candidates (candidate_id, candidate_revision, candidate_digest) ON DELETE RESTRICT;
ALTER TABLE core.supplier_relationship_assertion_evidence ADD CONSTRAINT supplier_assertion_evidence_parent_fk FOREIGN KEY (assertion_id, assertion_revision, assertion_digest) REFERENCES core.supplier_relationship_assertions (assertion_id, assertion_revision, assertion_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_query_snapshots ADD CONSTRAINT procurement_query_snapshot_generation_fk FOREIGN KEY (projection_generation_id, projection_generation_version, projection_generation_digest) REFERENCES core.dataset_snapshots (id, version, snapshot_sha256) ON DELETE RESTRICT;
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_members_parent_fk FOREIGN KEY (snapshot_id, snapshot_member_count, snapshot_member_set_digest) REFERENCES core.procurement_query_snapshots (snapshot_id, member_count, member_set_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_member_contract_fk FOREIGN KEY (contract_root_id, contract_revision_id, contract_revision, contract_record_digest) REFERENCES core.procurement_contract_revisions (root_id, revision_id, revision, record_digest) ON DELETE RESTRICT;
ALTER TABLE core.procurement_query_snapshot_members ADD CONSTRAINT procurement_query_snapshot_member_line_fk FOREIGN KEY (line_item_id, line_item_revision, line_item_digest) REFERENCES core.procurement_contract_line_item_revisions (line_item_id, line_item_revision, line_item_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.response_request_evidence_scopes ADD CONSTRAINT response_request_evidence_scope_claim_fk FOREIGN KEY (response_request_id, scope_version, claim_ordinal, claim_binding_digest) REFERENCES editorial.response_request_claim_scopes (response_request_id, scope_version, claim_ordinal, claim_binding_digest) ON DELETE RESTRICT;
-- Runtime owner boundaries for the three procurement identity commands.
-- This file is emitted inside additive migration 0025 by the migration
-- generator; it is kept separate so the generated migration remains
-- reproducible and the command bodies remain reviewable.

GRANT USAGE ON SCHEMA core, ops TO gurine_migrator;
GRANT SELECT, INSERT, UPDATE ON ops.users, ops.idempotency_keys, ops.audit_events, ops.audit_chain_heads, ops.outbox TO gurine_migrator;
GRANT EXECUTE ON FUNCTION ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb) TO gurine_migrator;

CREATE OR REPLACE FUNCTION core.record_supplier_identity_resolution_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid;
  v_actor_text text := COALESCE(NULLIF(current_setting('gurine.actor_user_id', true), ''), p_request->>'actorUserId');
  v_now timestamptz := clock_timestamp();
  v_canonical bytea;
  v_request_hash char(64);
  v_key_hash char(64);
  v_existing_hash char(64);
  v_existing_response jsonb;
  v_decision_id uuid := gen_random_uuid();
  v_event_id uuid := gen_random_uuid();
  v_audit_id uuid;
  v_decision_digest char(64);
  v_sequence bigint;
  v_action text := p_request->>'action';
  v_reason_code text := p_request->>'reasonCode';
  v_candidate_set_digest char(64) := p_request->>'expectedCandidateSetDigest';
  v_evidence_set_digest char(64) := p_request->>'expectedEvidenceLocatorSetDigest';
  v_impact_set_digest char(64) := p_request->>'expectedPublicImpactSetDigest';
  v_reason_digest char(64);
  v_prior_id uuid;
  v_prior_digest char(64);
  v_candidate jsonb;
  v_candidate_id uuid;
  v_candidate_revision bigint;
  v_candidate_digest char(64);
  v_member_canonical bytea;
  v_member_digest char(64);
  v_ordinal integer := 0;
  v_receipt jsonb;
  v_receipt_digest char(64);
  v_event_payload jsonb;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request) <> 'object' THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
  END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE = '28000';
  END IF;
  v_actor := v_actor_text::uuid;
  IF NOT EXISTS (SELECT 1 FROM ops.users WHERE id = v_actor AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'actor_user_not_active' USING ERRCODE = '28000';
  END IF;
  IF v_action NOT IN ('MERGE','SPLIT','KEEP_SEPARATE','MARK_AMBIGUOUS')
     OR v_reason_code NOT IN ('AUTHORITATIVE_IDENTIFIER_MATCH','AUTHORITATIVE_IDENTIFIER_CONFLICT','SOURCE_CORRECTION','FALSE_MERGE','INSUFFICIENT_EVIDENCE')
     OR jsonb_typeof(p_request->'candidateRefs') <> 'array'
     OR jsonb_array_length(p_request->'candidateRefs') < 1
     OR jsonb_typeof(p_request->'evidenceLocators') <> 'array'
     OR jsonb_array_length(p_request->'evidenceLocators') < 1
     OR v_candidate_set_digest !~ '^[0-9a-f]{64}$'
     OR v_evidence_set_digest !~ '^[0-9a-f]{64}$'
     OR v_impact_set_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
  END IF;
  IF v_action = 'MERGE' AND jsonb_array_length(p_request->'candidateRefs') < 2 THEN
    RAISE EXCEPTION 'invalid_merge_cardinality' USING ERRCODE = '22023';
  END IF;
  IF v_action = 'SPLIT' AND (jsonb_array_length(p_request->'candidateRefs') < 3 OR p_request->>'impactOwnerUserId' IS NULL OR p_request->>'impactDueAt' IS NULL) THEN
    RAISE EXCEPTION 'invalid_split_cardinality' USING ERRCODE = '22023';
  END IF;
  v_canonical := convert_to(p_request::text, 'UTF8');
  v_request_hash := encode(extensions.digest(v_canonical, 'sha256'), 'hex');
  v_key_hash := COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash', true), ''), v_request_hash);
  IF v_key_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_idempotency_key' USING ERRCODE = '22023'; END IF;
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
    VALUES ('recordSupplierIdentityResolution',v_key_hash,v_request_hash,v_now+interval '24 hours')
    ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT request_hash,response_body INTO v_existing_hash,v_existing_response
    FROM ops.idempotency_keys WHERE scope='recordSupplierIdentityResolution' AND key_hash=v_key_hash FOR UPDATE;
  IF v_existing_hash IS DISTINCT FROM v_request_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF;
  IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  SELECT COALESCE(max(decision_sequence),0)+1 INTO v_sequence FROM core.supplier_identity_resolution_decisions;
  v_decision_digest := encode(extensions.digest(v_canonical,'sha256'),'hex');
  SELECT decision_id,decision_digest INTO v_prior_id,v_prior_digest FROM core.supplier_identity_resolution_decisions WHERE decision_digest=NULLIF(p_request->>'expectedPriorDecisionDigest','') FOR SHARE;
  v_reason_digest := encode(extensions.digest(convert_to(COALESCE(p_request->>'reason',''),'UTF8'),'sha256'),'hex');
  v_event_payload := jsonb_build_object('occurredAt',v_now,'decisionId',v_decision_id,'decisionSequence',v_sequence,'action',v_action,'decisionDigest',v_decision_digest,'candidateSetDigest',v_candidate_set_digest,'evidenceLocatorSetDigest',v_evidence_set_digest);
  v_audit_id := ops.append_audit_event('supplier-identity-resolution','user',v_actor::text,NULL,'SUPPLIER_IDENTITY_RESOLUTION_RECORDED','SupplierIdentityResolutionDecision',v_decision_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt := jsonb_build_object('decisionId',v_decision_id,'decisionSequence',v_sequence,'action',v_action,'candidateSetDigest',v_candidate_set_digest,'evidenceLocatorSetDigest',v_evidence_set_digest,'publicImpactSetDigest',v_impact_set_digest,'decisionDigest',v_decision_digest,'actorUserId',v_actor,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
  v_event_payload := v_event_payload || jsonb_build_object('receiptId',v_decision_id,'receiptDigest',v_receipt_digest);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES(v_event_id,'SupplierIdentityResolutionDecision',v_decision_id::text,v_sequence,'supplier.identity_resolution_recorded.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_identity_resolution_decisions(decision_id,decision_sequence,action,candidate_count,candidate_set_digest,from_supplier_ids_canonical,from_supplier_set_digest,to_supplier_ids_canonical,to_supplier_set_digest,evidence_locator_set_canonical,evidence_locator_set_digest,prior_decision_id,prior_decision_digest,actor_user_id,reason_code,reason_digest,impact_owner_user_id,impact_due_at,affected_public_revision_ids_canonical,affected_public_revision_set_digest,decision_payload,decision_canonical,decision_digest_preimage_canonical,decision_digest,decided_at,audit_event_id,outbox_event_id)
    VALUES(v_decision_id,v_sequence,v_action,jsonb_array_length(p_request->'candidateRefs'),v_candidate_set_digest,convert_to(COALESCE(p_request->'fromCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),encode(extensions.digest(convert_to(COALESCE(p_request->'fromCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),convert_to(COALESCE(p_request->'toCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),encode(extensions.digest(convert_to(COALESCE(p_request->'toCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),convert_to((p_request->'evidenceLocators')::text,'UTF8'),v_evidence_set_digest,v_prior_id,v_prior_digest,v_actor,v_reason_code,v_reason_digest,NULLIF(p_request->>'impactOwnerUserId','')::uuid,NULLIF(p_request->>'impactDueAt','')::timestamptz,convert_to(COALESCE(p_request->'affectedPublicRevisionIds','[]'::jsonb)::text,'UTF8'),v_impact_set_digest,p_request,v_canonical,v_canonical,v_decision_digest,v_now,v_audit_id,v_event_id);
  FOR v_candidate IN SELECT value FROM jsonb_array_elements(p_request->'candidateRefs') LOOP
    v_candidate_id := NULLIF(v_candidate->>'candidateId','')::uuid; v_candidate_revision := NULLIF(v_candidate->>'candidateRevision','')::bigint; v_candidate_digest := v_candidate->>'candidateDigest';
    IF v_candidate_id IS NULL OR v_candidate_revision IS NULL OR v_candidate_revision < 1 OR v_candidate_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_candidate_reference' USING ERRCODE='22023'; END IF;
    PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_candidate_id AND candidate_revision=v_candidate_revision AND candidate_digest=v_candidate_digest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
    v_member_canonical := convert_to(v_candidate::text,'UTF8'); v_member_digest := encode(extensions.digest(v_member_canonical,'sha256'),'hex');
    INSERT INTO core.supplier_identity_resolution_decision_members(decision_id,decision_digest,member_ordinal,candidate_id,candidate_revision,candidate_digest,member_canonical,member_digest) VALUES(v_decision_id,v_decision_digest,v_ordinal,v_candidate_id,v_candidate_revision,v_candidate_digest,v_member_canonical,v_member_digest);
    v_ordinal := v_ordinal + 1;
  END LOOP;
  UPDATE ops.idempotency_keys SET response_status=201,response_body=v_receipt,resource_type='SupplierIdentityResolutionDecision',resource_id=v_decision_id::text WHERE scope='recordSupplierIdentityResolution' AND key_hash=v_key_hash;
  RETURN v_receipt;
END
$$;
ALTER FUNCTION core.record_supplier_identity_resolution_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.record_supplier_identity_resolution_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.record_supplier_identity_resolution_v1(jsonb) TO gurine_identity_api;

CREATE OR REPLACE FUNCTION core.record_supplier_relationship_assertion_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid;
  v_actor_text text := COALESCE(NULLIF(current_setting('gurine.actor_user_id', true), ''), p_request->>'actorUserId');
  v_now timestamptz := clock_timestamp();
  v_id uuid := gen_random_uuid(); v_event_id uuid := gen_random_uuid(); v_audit_id uuid;
  v_canonical bytea := convert_to(p_request::text,'UTF8'); v_digest char(64) := encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_key_hash char(64); v_existing_hash char(64); v_existing_response jsonb; v_receipt jsonb; v_receipt_digest char(64); v_event_payload jsonb;
  v_subject jsonb := p_request->'subject'; v_object jsonb := p_request->'object'; v_loc jsonb; v_ordinal integer := 0; v_loc_canonical bytea;
  v_subject_id uuid := NULLIF(v_subject->>'supplierCandidateId','')::uuid; v_subject_rev bigint := NULLIF(v_subject->>'supplierCandidateRevision','')::bigint; v_subject_digest char(64) := v_subject->>'supplierCandidateDigest'; v_subject_key char(64) := v_subject->>'identityKeyDigest';
  v_object_id uuid := NULLIF(v_object->>'supplierCandidateId','')::uuid; v_object_rev bigint := NULLIF(v_object->>'supplierCandidateRevision','')::bigint; v_object_digest char(64) := v_object->>'supplierCandidateDigest'; v_object_key char(64) := v_object->>'identityKeyDigest';
  v_evidence_set_digest char(64) := p_request->>'expectedEvidenceLocatorSetDigest';
  v_evidence_id uuid; v_evidence_version bigint; v_evidence_digest char(64); v_snapshot_id uuid; v_case_id uuid; v_snapshot_version bigint; v_snapshot_digest char(64); v_source_document_id uuid; v_source_asset_id uuid; v_source_asset_revision bigint; v_source_content_sha256 char(64); v_locator_digest char(64);
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object' OR p_request->>'relationshipKind' NOT IN ('OWNERSHIP','BENEFICIAL_OWNERSHIP','CONTROL','MANAGEMENT_ROLE','LEGAL_REPRESENTATIVE','CONTRACTUAL_RELATIONSHIP') OR jsonb_typeof(p_request->'evidenceLocators')<>'array' OR jsonb_array_length(p_request->'evidenceLocators')<1 OR v_evidence_set_digest !~ '^[0-9a-f]{64}$' OR v_subject_key !~ '^[0-9a-f]{64}$' OR v_object_key !~ '^[0-9a-f]{64}$' OR v_subject_key=v_object_key THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE='28000'; END IF;
  v_actor := v_actor_text::uuid; IF NOT EXISTS (SELECT 1 FROM ops.users WHERE id=v_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'actor_user_not_active' USING ERRCODE='28000'; END IF;
  IF v_subject_id IS NOT NULL THEN PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_subject_id AND candidate_revision=v_subject_rev AND candidate_digest=v_subject_digest FOR SHARE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF; END IF;
  IF v_object_id IS NOT NULL THEN PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_object_id AND candidate_revision=v_object_rev AND candidate_digest=v_object_digest FOR SHARE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF; END IF;
  v_key_hash := COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash', true),''),encode(extensions.digest(v_canonical,'sha256'),'hex'));
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES('recordSupplierRelationshipAssertion',v_key_hash,v_digest,v_now+interval '24 hours') ON CONFLICT(scope,key_hash) DO NOTHING;
  SELECT request_hash,response_body INTO v_existing_hash,v_existing_response FROM ops.idempotency_keys WHERE scope='recordSupplierRelationshipAssertion' AND key_hash=v_key_hash FOR UPDATE;
  IF v_existing_hash IS DISTINCT FROM v_digest THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF; IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  v_event_payload := jsonb_build_object('occurredAt',v_now,'assertionId',v_id,'assertionRevision',1,'assertionDigest',v_digest,'verificationStatus','PENDING','evidenceLocatorSetDigest',v_evidence_set_digest);
  v_audit_id := ops.append_audit_event('supplier-relationship-assertion','user',v_actor::text,NULL,'SUPPLIER_RELATIONSHIP_ASSERTION_CREATED','SupplierRelationshipAssertion',v_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt := jsonb_build_object('assertionId',v_id,'assertionRevision',1,'assertionDigest',v_digest,'verificationStatus','PENDING','evidenceLocatorSetDigest',v_evidence_set_digest,'verifiedBy',NULL,'verifiedAt',NULL,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex'); v_event_payload := v_event_payload || jsonb_build_object('receiptId',v_id,'receiptDigest',v_receipt_digest);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_event_id,'SupplierRelationshipAssertion',v_id::text,1,'supplier.relationship_assertion_created.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_relationship_assertions(assertion_id,assertion_revision,assertion_digest,relationship_kind,subject_candidate_id,subject_candidate_revision,subject_candidate_digest,subject_identity_key_digest,object_candidate_id,object_candidate_revision,object_candidate_digest,object_identity_key_digest,ownership_percent,management_role,valid_from,valid_to,validity_coverage_status,verification_status,evidence_count,evidence_set_digest,counter_assertion_set_digest,public_use_status,created_by,assertion_payload,assertion_canonical,assertion_digest_preimage_canonical)
    VALUES(v_id,1,v_digest,p_request->>'relationshipKind',v_subject_id,v_subject_rev,v_subject_digest,v_subject_key,v_object_id,v_object_rev,v_object_digest,v_object_key,NULLIF(p_request->>'ownershipPercent','')::numeric,NULLIF(p_request->>'managementRole',''),NULLIF(p_request->>'validFrom','')::date,NULLIF(p_request->>'validTo','')::date,p_request->>'validityCoverageStatus','PENDING',jsonb_array_length(p_request->'evidenceLocators'),v_evidence_set_digest,encode(extensions.digest(convert_to('[]','UTF8'),'sha256'),'hex'),'NOT_REVIEWED',v_actor,p_request,v_canonical,v_canonical);
  FOR v_loc IN SELECT value FROM jsonb_array_elements(p_request->'evidenceLocators') LOOP
    v_evidence_id := NULLIF(v_loc->>'evidenceId','')::uuid; v_evidence_version := NULLIF(v_loc->>'evidenceVersion','')::bigint; v_evidence_digest := v_loc->>'evidenceDigest'; v_snapshot_id := NULLIF(v_loc->>'reviewSnapshotId','')::uuid; v_case_id := NULLIF(v_loc->>'reviewCaseId','')::uuid; v_snapshot_version := NULLIF(v_loc->>'reviewSnapshotVersion','')::bigint; v_snapshot_digest := v_loc->>'reviewSnapshotDigest'; v_source_document_id := NULLIF(v_loc->>'sourceDocumentId','')::uuid; v_source_asset_id := NULLIF(v_loc->>'sourceAssetId','')::uuid; v_source_asset_revision := NULLIF(v_loc->>'sourceAssetRevision','')::bigint; v_source_content_sha256 := v_loc->>'sourceContentSha256'; v_locator_digest := v_loc->>'locatorDigest';
    IF v_evidence_id IS NULL OR v_evidence_version<1 OR v_evidence_digest !~ '^[0-9a-f]{64}$' OR v_snapshot_id IS NULL OR v_case_id IS NULL OR v_snapshot_version<1 OR v_snapshot_digest !~ '^[0-9a-f]{64}$' OR v_source_document_id IS NULL OR v_source_asset_id IS NULL OR v_source_asset_revision<1 OR v_source_content_sha256 !~ '^[0-9a-f]{64}$' OR v_locator_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_evidence_locator' USING ERRCODE='22023'; END IF;
    v_loc_canonical := convert_to(v_loc::text,'UTF8'); INSERT INTO core.supplier_relationship_assertion_evidence(assertion_id,assertion_revision,assertion_digest,evidence_ordinal,review_snapshot_id,review_case_id,review_snapshot_version,review_snapshot_digest,evidence_id,evidence_version,evidence_digest,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,locator_digest,evidence_binding_canonical,evidence_member_digest) VALUES(v_id,1,v_digest,v_ordinal,v_snapshot_id,v_case_id,v_snapshot_version,v_snapshot_digest,v_evidence_id,v_evidence_version,v_evidence_digest,v_source_document_id,v_source_asset_id,v_source_asset_revision,v_source_content_sha256,v_locator_digest,v_loc_canonical,encode(extensions.digest(v_loc_canonical,'sha256'),'hex')); v_ordinal:=v_ordinal+1;
  END LOOP;
  UPDATE ops.idempotency_keys SET response_status=201,response_body=v_receipt,resource_type='SupplierRelationshipAssertion',resource_id=v_id::text WHERE scope='recordSupplierRelationshipAssertion' AND key_hash=v_key_hash;
  RETURN v_receipt;
END
$$;
ALTER FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) TO gurine_identity_api;

CREATE OR REPLACE FUNCTION core.decide_supplier_relationship_assertion_v1(p_assertion_id uuid,p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid; v_actor_text text:=COALESCE(NULLIF(current_setting('gurine.actor_user_id',true),''),p_request->>'actorUserId'); v_current core.supplier_relationship_assertions%ROWTYPE; v_now timestamptz:=clock_timestamp(); v_status text; v_revision bigint; v_preimage bytea; v_digest char(64); v_event_id uuid:=gen_random_uuid(); v_audit_id uuid; v_receipt jsonb; v_receipt_digest char(64); v_event_payload jsonb; v_key_hash char(64); v_existing_hash char(64); v_existing_response jsonb; v_request_hash char(64):=encode(extensions.digest(convert_to(p_request::text,'UTF8'),'sha256'),'hex'); v_loc record;
BEGIN
  IF p_assertion_id IS NULL OR p_request IS NULL OR p_request->>'decision' NOT IN ('VERIFY','REJECT','MARK_CONFLICT','SUPERSEDE') OR p_request->>'expectedAssertionDigest' !~ '^[0-9a-f]{64}$' OR p_request->>'expectedEvidenceLocatorSetDigest' !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE='28000'; END IF; v_actor:=v_actor_text::uuid;
  SELECT * INTO v_current FROM core.supplier_relationship_assertions WHERE assertion_id=p_assertion_id ORDER BY assertion_revision DESC LIMIT 1 FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF v_current.assertion_revision<>(p_request->>'expectedAssertionRevision')::bigint OR v_current.assertion_digest<>p_request->>'expectedAssertionDigest' THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF; IF v_current.verification_status<>'PENDING' OR v_current.created_by=v_actor THEN RAISE EXCEPTION 'independent_decision_required' USING ERRCODE='42501'; END IF;
  v_key_hash:=COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash',true),''),encode(extensions.digest(convert_to(p_assertion_id::text||':'||v_request_hash,'UTF8'),'sha256'),'hex')); INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES('decideSupplierRelationshipAssertion',v_key_hash,v_request_hash,v_now+interval '24 hours') ON CONFLICT(scope,key_hash) DO NOTHING; SELECT request_hash,response_body INTO v_existing_hash,v_existing_response FROM ops.idempotency_keys WHERE scope='decideSupplierRelationshipAssertion' AND key_hash=v_key_hash FOR UPDATE; IF v_existing_hash IS DISTINCT FROM v_request_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF; IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  v_status:=CASE p_request->>'decision' WHEN 'VERIFY' THEN 'VERIFIED' WHEN 'REJECT' THEN 'REJECTED' WHEN 'MARK_CONFLICT' THEN 'CONFLICTED' ELSE 'SUPERSEDED' END; v_revision:=v_current.assertion_revision+1; v_preimage:=convert_to(jsonb_build_object('priorAssertionDigest',v_current.assertion_digest,'decision',p_request->>'decision','reasonCode',p_request->>'reasonCode','reason',p_request->>'reason','counterAssertionIds',COALESCE(p_request->'counterAssertionIds','[]'::jsonb))::text,'UTF8'); v_digest:=encode(extensions.digest(v_preimage,'sha256'),'hex');
  v_event_payload:=jsonb_build_object('occurredAt',v_now,'assertionId',p_assertion_id,'assertionRevision',v_revision,'assertionDigest',v_digest,'verificationStatus',v_status,'evidenceLocatorSetDigest',v_current.evidence_set_digest,'decisionDigest',v_digest); v_audit_id:=ops.append_audit_event('supplier-relationship-assertion','user',v_actor::text,NULL,'SUPPLIER_RELATIONSHIP_ASSERTION_DECIDED','SupplierRelationshipAssertion',p_assertion_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt:=jsonb_build_object('assertionId',p_assertion_id,'assertionRevision',v_revision,'assertionDigest',v_digest,'verificationStatus',v_status,'evidenceLocatorSetDigest',v_current.evidence_set_digest,'verifiedBy',v_actor,'verifiedAt',v_now,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now); v_receipt_digest:=encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex'); v_event_payload:=v_event_payload||jsonb_build_object('receiptId',p_assertion_id,'receiptDigest',v_receipt_digest); INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_event_id,'SupplierRelationshipAssertion',p_assertion_id::text,v_revision,'supplier.relationship_assertion_decided.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_relationship_assertions(assertion_id,assertion_revision,assertion_digest,predecessor_assertion_revision,predecessor_assertion_digest,relationship_kind,subject_candidate_id,subject_candidate_revision,subject_candidate_digest,subject_identity_key_digest,object_candidate_id,object_candidate_revision,object_candidate_digest,object_identity_key_digest,ownership_percent,management_role,valid_from,valid_to,validity_coverage_status,verification_status,evidence_count,evidence_set_digest,counter_assertion_set_digest,verified_by,verified_at,verification_reason_digest,public_use_status,created_by,assertion_payload,assertion_canonical,assertion_digest_preimage_canonical) VALUES(p_assertion_id,v_revision,v_digest,v_current.assertion_revision,v_current.assertion_digest,v_current.relationship_kind,v_current.subject_candidate_id,v_current.subject_candidate_revision,v_current.subject_candidate_digest,v_current.subject_identity_key_digest,v_current.object_candidate_id,v_current.object_candidate_revision,v_current.object_candidate_digest,v_current.object_identity_key_digest,v_current.ownership_percent,v_current.management_role,v_current.valid_from,v_current.valid_to,v_current.validity_coverage_status,v_status,v_current.evidence_count,v_current.evidence_set_digest,encode(extensions.digest(convert_to(COALESCE(p_request->'counterAssertionIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),v_actor,v_now,encode(extensions.digest(convert_to(COALESCE(p_request->>'reason',''),'UTF8'),'sha256'),'hex'),CASE WHEN v_status='VERIFIED' AND v_current.validity_coverage_status='COMPLETE' THEN 'APPROVED' ELSE 'NOT_REVIEWED' END,v_current.created_by,jsonb_build_object('priorAssertionDigest',v_current.assertion_digest,'decision',p_request->>'decision','reasonCode',p_request->>'reasonCode','reason',p_request->>'reason','counterAssertionIds',COALESCE(p_request->'counterAssertionIds','[]'::jsonb)),v_preimage,v_preimage);
  FOR v_loc IN SELECT * FROM core.supplier_relationship_assertion_evidence WHERE assertion_id=p_assertion_id AND assertion_revision=v_current.assertion_revision ORDER BY evidence_ordinal LOOP INSERT INTO core.supplier_relationship_assertion_evidence(assertion_id,assertion_revision,assertion_digest,evidence_ordinal,review_snapshot_id,review_case_id,review_snapshot_version,review_snapshot_digest,evidence_id,evidence_version,evidence_digest,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,locator_digest,evidence_binding_canonical,evidence_member_digest) VALUES(p_assertion_id,v_revision,v_digest,v_loc.evidence_ordinal,v_loc.review_snapshot_id,v_loc.review_case_id,v_loc.review_snapshot_version,v_loc.review_snapshot_digest,v_loc.evidence_id,v_loc.evidence_version,v_loc.evidence_digest,v_loc.source_document_id,v_loc.source_asset_id,v_loc.source_asset_revision,v_loc.source_content_sha256,v_loc.locator_digest,v_loc.evidence_binding_canonical,encode(extensions.digest(v_loc.evidence_binding_canonical,'sha256'),'hex')); END LOOP;
  UPDATE ops.idempotency_keys SET response_status=200,response_body=v_receipt,resource_type='SupplierRelationshipAssertion',resource_id=p_assertion_id::text WHERE scope='decideSupplierRelationshipAssertion' AND key_hash=v_key_hash; RETURN v_receipt;
END
$$;
ALTER FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) TO gurine_identity_api;
CREATE INDEX normalization_runs_source_idx ON core.normalization_runs (source_document_id, started_at DESC, id);
CREATE INDEX normalization_runs_output_idx ON core.normalization_runs (output_object_type, output_object_id, output_object_version) WHERE state='SUCCEEDED';
CREATE INDEX evidence_segments_source_idx ON raw.evidence_segments (source_document_id, segment_ordinal);
CREATE INDEX evidence_segments_asset_locator_idx ON raw.evidence_segments (source_asset_id, source_asset_revision, locator_digest);
CREATE INDEX evidence_segments_parser_idx ON raw.evidence_segments (parser_run_id, segment_ordinal);
CREATE INDEX dataset_snapshots_current_idx ON core.dataset_snapshots (snapshot_kind, producer_key, producer_generation DESC) WHERE state='READY';
CREATE INDEX dataset_snapshots_digest_idx ON core.dataset_snapshots (snapshot_kind, producer_digest, producer_generation DESC);
CREATE INDEX dataset_snapshot_members_order_idx ON core.dataset_snapshot_members (dataset_snapshot_id, object_type, object_id, object_version);
CREATE INDEX dataset_snapshot_members_object_idx ON core.dataset_snapshot_members (object_type, object_id, object_version);
CREATE INDEX dataset_snapshot_member_sources_document_idx ON core.dataset_snapshot_member_sources (source_document_id, source_asset_revision);
CREATE INDEX dataset_snapshot_member_sources_member_idx ON core.dataset_snapshot_member_sources (dataset_snapshot_id, snapshot_member_id, source_ordinal);
CREATE INDEX agent_provider_turns_run_idx ON ops.agent_provider_turns (agent_run_id, turn_sequence, attempt_sequence);
CREATE INDEX agent_provider_turns_terminal_idx ON ops.agent_provider_turns (agent_run_id, status, completed_at DESC);
CREATE INDEX agent_tool_calls_run_idx ON ops.agent_tool_calls (agent_run_id, started_at, tool_call_id);
CREATE INDEX agent_tool_calls_lease_idx ON ops.agent_tool_calls (status, lease_expires_at) WHERE status='CLAIMED';
CREATE INDEX research_artifacts_run_idx ON raw.research_artifacts (agent_run_id, created_at, id);
CREATE INDEX research_artifacts_asset_idx ON raw.research_artifacts (asset_id, asset_revision);
CREATE INDEX research_artifacts_content_idx ON raw.research_artifacts (content_sha256);
CREATE INDEX agent_output_validations_run_idx ON ops.agent_output_validations (agent_run_id, validated_at DESC);
CREATE INDEX agent_proposal_citations_source_idx ON ops.agent_proposal_citations (source_kind, source_id);
CREATE INDEX agent_proposal_citations_validation_idx ON ops.agent_proposal_citations (validation_id, proposal_id, citation_ordinal);
CREATE INDEX asset_rights_current_idx ON raw.asset_rights_decisions (asset_id, asset_sha256, decision_version DESC);
CREATE INDEX asset_rights_expiry_idx ON raw.asset_rights_decisions (expires_at, asset_id) WHERE expires_at IS NOT NULL;
CREATE INDEX agent_reconciliation_evidence_run_idx ON ops.agent_reconciliation_evidence (agent_run_id, observed_at DESC, evidence_id);
CREATE INDEX agent_reconciliation_evidence_turn_idx ON ops.agent_reconciliation_evidence (agent_run_id, provider_turn_id) WHERE provider_turn_id IS NOT NULL;
CREATE INDEX agent_reconciliation_evidence_tool_idx ON ops.agent_reconciliation_evidence (agent_run_id, tool_call_id) WHERE tool_call_id IS NOT NULL;
CREATE INDEX agent_reconciliation_evidence_receipt_idx ON ops.agent_reconciliation_evidence (agent_run_id, provider_turn_id, provider_receipt_id, provider_receipt_sha256) WHERE provider_turn_id IS NOT NULL AND provider_receipt_id IS NOT NULL AND provider_receipt_sha256 IS NOT NULL;
CREATE INDEX agent_run_control_receipts_run_idx ON ops.agent_run_control_receipts (agent_run_id, aggregate_version DESC);
CREATE INDEX agent_run_control_receipts_proof_idx ON ops.agent_run_control_receipts (proof_kind, occurred_at DESC, receipt_id);
CREATE INDEX agent_run_control_receipts_reconciliation_idx ON ops.agent_run_control_receipts (agent_run_id, reconciliation_evidence_id, reconciliation_evidence_sha256) WHERE reconciliation_evidence_id IS NOT NULL AND reconciliation_evidence_sha256 IS NOT NULL;
CREATE INDEX agent_source_uses_run_idx ON ops.agent_source_uses (agent_run_id, occurred_at, source_use_id);
CREATE INDEX agent_source_uses_source_idx ON ops.agent_source_uses (source_kind, object_id, research_artifact_id, evidence_segment_id, response_id);
CREATE INDEX agent_source_uses_parent_idx ON ops.agent_source_uses (agent_run_id, parent_source_use_id);
CREATE INDEX agent_source_uses_promotion_idx ON ops.agent_source_uses (promotion_id, source_use_id) WHERE promotion_id IS NOT NULL;
CREATE INDEX research_artifact_promotions_case_idx ON raw.research_artifact_promotions (case_id, promoted_at DESC, promotion_id);
CREATE INDEX research_artifact_promotions_artifact_idx ON raw.research_artifact_promotions (research_artifact_id, promoted_at DESC);
CREATE INDEX public_search_documents_vector_idx ON public.search_documents USING gin (search_vector);
CREATE INDEX public_search_documents_title_trgm_idx ON public.search_documents USING gin (normalized_title extensions.gin_trgm_ops);
CREATE INDEX public_search_documents_identifier_idx ON public.search_documents (projection_generation_id, normalized_identifier_key, object_type_order, object_id, object_revision);
CREATE INDEX public_search_documents_relevance_idx ON public.search_documents (projection_generation_id, object_type_order, normalized_title, object_id, object_revision);
CREATE INDEX public_search_documents_updated_idx ON public.search_documents (projection_generation_id, source_updated_at DESC, normalized_title, object_type_order, object_id, object_revision);
CREATE INDEX public_search_documents_filter_idx ON public.search_documents (projection_generation_id, object_type, publication_state, search_date, document_watermark);
CREATE INDEX ops_search_documents_vector_idx ON ops.search_documents USING gin (search_vector);
CREATE INDEX ops_search_documents_title_trgm_idx ON ops.search_documents USING gin (normalized_title extensions.gin_trgm_ops);
CREATE INDEX ops_search_documents_scope_idx ON ops.search_documents (projection_generation_id, authorization_scope_type, authorization_scope_id, classification, object_type, status, document_watermark);
CREATE INDEX ops_search_documents_capability_idx ON ops.search_documents USING gin (required_capabilities);
CREATE INDEX ops_search_documents_relevance_idx ON ops.search_documents (projection_generation_id, object_type_order, normalized_title, object_id, object_revision);
CREATE INDEX ops_search_documents_updated_idx ON ops.search_documents (projection_generation_id, source_updated_at DESC, normalized_title, object_type_order, object_id, object_revision);
CREATE INDEX source_page_receipts_traversal_idx ON raw.source_page_receipts (source_run_id, connector_id, operation_id, partition_key, ordinal);
CREATE INDEX source_page_receipts_checkpoint_idx ON raw.source_page_receipts (source_id, partition_key, checkpoint_expected_version, ordinal DESC);
CREATE INDEX source_page_receipts_terminal_idx ON raw.source_page_receipts (source_run_id, terminal_page) WHERE terminal_page;
CREATE INDEX procurement_notice_source_idx ON core.procurement_notice_revisions (source_document_id, record_index, revision_id);
CREATE INDEX procurement_notice_external_idx ON core.procurement_notice_revisions (external_notice_id, revision DESC, revision_id);
CREATE INDEX procurement_notice_agency_idx ON core.procurement_notice_revisions (agency_id, published_at DESC, revision_id);
CREATE UNIQUE INDEX procurement_notice_one_successor_uq ON core.procurement_notice_revisions (supersedes_revision_id) WHERE supersedes_revision_id IS NOT NULL;
CREATE INDEX procurement_award_notice_idx ON core.procurement_award_revisions (notice_revision_id, awarded_at_value, revision_id);
CREATE UNIQUE INDEX procurement_award_one_successor_uq ON core.procurement_award_revisions (supersedes_revision_id) WHERE supersedes_revision_id IS NOT NULL;
CREATE INDEX procurement_award_winner_candidate_idx ON core.procurement_award_winner_revisions (candidate_id, candidate_revision, award_revision_id);
CREATE INDEX procurement_bidder_notice_candidate_idx ON core.procurement_bidder_participation_revisions (notice_revision_id, candidate_id, revision DESC);
CREATE UNIQUE INDEX procurement_bidder_one_successor_uq ON core.procurement_bidder_participation_revisions (supersedes_revision_id) WHERE supersedes_revision_id IS NOT NULL;
CREATE INDEX procurement_contract_agency_signed_idx ON core.procurement_contract_revisions (agency_id, signed_at DESC, revision_id);
CREATE INDEX procurement_contract_notice_idx ON core.procurement_contract_revisions (notice_revision_id, revision_id) WHERE notice_revision_id IS NOT NULL;
CREATE UNIQUE INDEX procurement_contract_one_successor_uq ON core.procurement_contract_revisions (supersedes_revision_id) WHERE supersedes_revision_id IS NOT NULL;
CREATE INDEX procurement_contract_supplier_candidate_idx ON core.procurement_contract_supplier_revisions (candidate_id, candidate_revision, contract_revision_id);
CREATE INDEX procurement_amendment_contract_idx ON core.procurement_contract_amendment_revisions (after_contract_root_id, amendment_sequence, revision_id);
CREATE UNIQUE INDEX procurement_amendment_one_successor_uq ON core.procurement_contract_amendment_revisions (supersedes_revision_id) WHERE supersedes_revision_id IS NOT NULL;
CREATE INDEX procurement_line_item_contract_idx ON core.procurement_contract_line_item_revisions (contract_revision_id, line_ordinal, line_item_id);
CREATE INDEX procurement_line_item_normalized_idx ON core.procurement_contract_line_item_revisions (category_code, normalized_unit, total_price, line_item_id);
CREATE INDEX procurement_line_item_components_parent_fk_idx ON core.procurement_contract_line_item_revisions (line_item_id, line_item_revision, line_item_digest);
CREATE UNIQUE INDEX procurement_line_item_one_successor_uq ON core.procurement_contract_line_item_revisions (predecessor_line_item_revision_id) WHERE predecessor_line_item_revision_id IS NOT NULL;
CREATE INDEX procurement_line_item_component_source_idx ON core.procurement_contract_line_item_components (source_locator_digest, line_item_id, line_item_revision);
CREATE INDEX procurement_line_item_components_parent_fk_idx_core_procurement ON core.procurement_contract_line_item_components (line_item_id, line_item_revision, line_item_digest);
CREATE INDEX supplier_candidate_name_idx ON core.supplier_identity_candidates (normalized_name, candidate_id, candidate_revision DESC);
CREATE INDEX supplier_candidate_status_idx ON core.supplier_identity_candidates (identity_status, created_at, candidate_id);
CREATE UNIQUE INDEX supplier_candidate_one_successor_uq ON core.supplier_identity_candidates (candidate_id, predecessor_candidate_revision) WHERE predecessor_candidate_revision IS NOT NULL;
CREATE INDEX supplier_resolution_decided_idx ON core.supplier_identity_resolution_decisions (decided_at DESC, decision_id);
CREATE INDEX supplier_resolution_actor_idx ON core.supplier_identity_resolution_decisions (actor_user_id, decided_at DESC, decision_id);
CREATE INDEX supplier_resolution_member_candidate_idx ON core.supplier_identity_resolution_decision_members (candidate_id, candidate_revision, decision_id);
CREATE INDEX supplier_assertion_subject_idx ON core.supplier_relationship_assertions (subject_identity_key_digest, relationship_kind, valid_from, assertion_id, assertion_revision);
CREATE INDEX supplier_assertion_object_idx ON core.supplier_relationship_assertions (object_identity_key_digest, relationship_kind, valid_from, assertion_id, assertion_revision);
CREATE UNIQUE INDEX supplier_assertion_one_successor_uq ON core.supplier_relationship_assertions (assertion_id, predecessor_assertion_revision) WHERE predecessor_assertion_revision IS NOT NULL;
CREATE INDEX supplier_assertion_evidence_source_idx ON core.supplier_relationship_assertion_evidence (source_document_id, locator_digest, assertion_id, assertion_revision);
CREATE INDEX supplier_assertion_evidence_snapshot_idx ON core.supplier_relationship_assertion_evidence (review_snapshot_id, evidence_ordinal);
CREATE INDEX procurement_query_snapshot_filter_idx ON core.procurement_query_snapshots (filter_digest, visibility_as_of DESC, snapshot_id);
CREATE INDEX procurement_query_snapshot_expiry_idx ON core.procurement_query_snapshots (expires_at, snapshot_id);
CREATE INDEX procurement_query_snapshot_member_contract_idx ON core.procurement_query_snapshot_members (contract_revision_id, line_item_id, snapshot_id);
CREATE INDEX procurement_query_snapshot_member_order_idx ON core.procurement_query_snapshot_members (snapshot_id, member_ordinal);
CREATE INDEX procurement_query_snapshot_members_parent_fk_idx ON core.procurement_query_snapshot_members (snapshot_id, snapshot_member_count, snapshot_member_set_digest);
CREATE INDEX procurement_query_snapshot_member_contract_fk_idx ON core.procurement_query_snapshot_members (contract_root_id, contract_revision_id, contract_revision, contract_record_digest);
CREATE INDEX procurement_query_snapshot_member_line_fk_idx ON core.procurement_query_snapshot_members (line_item_id, line_item_revision, line_item_digest);
CREATE INDEX response_request_claim_scope_claim_idx ON editorial.response_request_claim_scopes (claim_id, claim_revision, response_request_id, scope_version);
CREATE INDEX response_request_claim_scope_snapshot_idx ON editorial.response_request_claim_scopes (review_snapshot_id, claim_ordinal);
CREATE INDEX response_request_evidence_scope_source_idx ON editorial.response_request_evidence_scopes (source_document_id, locator_digest, response_request_id);
CREATE INDEX response_request_evidence_scope_order_idx ON editorial.response_request_evidence_scopes (response_request_id, scope_version, claim_ordinal, evidence_ordinal);
COMMIT;
