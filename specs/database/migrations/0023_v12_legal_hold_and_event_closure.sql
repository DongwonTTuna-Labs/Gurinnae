BEGIN;

CREATE INDEX IF NOT EXISTS legal_holds_review_snapshot_idx
  ON editorial.legal_holds(review_snapshot_id,active,placed_at DESC);

REVOKE ALL ON TABLE editorial.legal_holds FROM PUBLIC;
REVOKE UPDATE,DELETE ON TABLE editorial.legal_holds FROM gurine_control_api;
GRANT SELECT,INSERT ON TABLE editorial.legal_holds TO gurine_control_api;
GRANT SELECT ON TABLE editorial.legal_holds TO gurine_auditor;

INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
 ('legal_hold.placed.v1','DOMAIN',1,true,'payloads/legal_hold_placed_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET category=EXCLUDED.category,schema_version=EXCLUDED.schema_version,active=EXCLUDED.active,payload_schema_uri=EXCLUDED.payload_schema_uri;

COMMIT;
