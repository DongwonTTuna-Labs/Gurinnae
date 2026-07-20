BEGIN;

DROP FUNCTION IF EXISTS ops.consume_step_up_proof(char(64),uuid,char(64),text,uuid);
DROP TABLE IF EXISTS ops.step_up_proofs;

COMMIT;
