INSERT INTO editorial.legal_holds(
  id,case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,
  reason,authority_reference,active,version,placed_by)
VALUES(
  'f2e3dba2-ad34-58be-b3a3-128a4dbdf737',
  '148b09d5-aa28-5351-b471-9ef333a3e410',
  '04935ea9-f702-552c-aedc-425382a2d2b3',
  'CASE','148b09d5-aa28-5351-b471-9ef333a3e410','ALL','[]'::jsonb,
  'Control-flow legal hold fixture','control-fixture-authority',true,1,
  '11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;
