BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

SELECT pg_catalog.set_config(
  'gurine.role_provisioner_expected_actor',
  :'expected_actor',
  true
);
SELECT pg_catalog.set_config(
  'gurine.r6e_migration_checksum_sha384',
  :'expected_migration_checksum',
  true
);

SELECT pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended(
    'gurinnae:r6e-runtime-role-provisioning:v1',
    0
  )
);

DO $r6e_role_provisioning$
DECLARE
  v_actor text := pg_catalog.current_setting(
    'gurine.role_provisioner_expected_actor'
  );
  v_expected_checksum text := pg_catalog.current_setting(
    'gurine.r6e_migration_checksum_sha384'
  );
  v_expected record;
  v_role_oid oid;
  v_database_oid oid;
  v_existing_role_count bigint;
  v_ledger regclass := pg_catalog.to_regclass('public._sqlx_migrations');
  v_ledger_count bigint := 0;
  v_failed_count bigint := 0;
  v_min_version bigint;
  v_max_version bigint;
  v_row_41_count bigint := 0;
  v_row_41_success boolean;
  v_row_41_description text;
  v_row_41_checksum text;
  v_post_0041 boolean := false;
  v_postcondition boolean;
BEGIN
  IF session_user <> v_actor
    OR current_user <> session_user
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_roles AS actor
      WHERE actor.rolname=v_actor
        AND actor.rolsuper
    )
  THEN
    RAISE EXCEPTION 'R6E_ROLE_PROVISIONER_ACTOR_INVALID'
      USING ERRCODE='42501';
  END IF;

  IF v_expected_checksum !~ '^[0-9a-f]{96}$' THEN
    RAISE EXCEPTION 'R6E_MIGRATION_CHECKSUM_INVALID'
      USING ERRCODE='22023';
  END IF;

  SELECT oid INTO STRICT v_database_oid
  FROM pg_catalog.pg_database
  WHERE datname=pg_catalog.current_database();

  IF v_ledger IS NOT NULL THEN
    EXECUTE pg_catalog.format(
      'SELECT count(*)::bigint, '
      'count(*) FILTER (WHERE NOT success)::bigint, '
      'min(version)::bigint, max(version)::bigint, '
      'count(*) FILTER (WHERE version=41)::bigint, '
      'bool_and(success) FILTER (WHERE version=41), '
      'max(description) FILTER (WHERE version=41), '
      'max(encode(checksum,''hex'')) FILTER (WHERE version=41) '
      'FROM %s',
      v_ledger
    ) INTO
      v_ledger_count,
      v_failed_count,
      v_min_version,
      v_max_version,
      v_row_41_count,
      v_row_41_success,
      v_row_41_description,
      v_row_41_checksum;

    IF v_row_41_count=1 THEN
      IF v_ledger_count<>41
        OR v_failed_count<>0
        OR v_min_version<>1
        OR v_max_version<>41
        OR v_row_41_success IS DISTINCT FROM true
        OR v_row_41_description IS DISTINCT FROM 'r6e monetization runtime'
        OR v_row_41_checksum IS DISTINCT FROM v_expected_checksum
      THEN
        RAISE EXCEPTION 'R6E_POST_0041_LEDGER_INVALID'
          USING ERRCODE='55000';
      END IF;
      v_post_0041 := true;
    ELSIF v_row_41_count<>0
      OR v_failed_count<>0
      OR v_max_version>40
      OR (
        v_ledger_count<>0
        AND (
          v_min_version<>1
          OR v_ledger_count<>v_max_version
        )
      )
    THEN
      RAISE EXCEPTION 'R6E_PRE_0041_LEDGER_INVALID'
        USING ERRCODE='55000';
    END IF;
  END IF;

  IF NOT v_post_0041 AND v_ledger_count=0 AND (
    EXISTS (
      SELECT 1
      FROM pg_catalog.pg_namespace AS namespace
      WHERE namespace.nspname IN (
        'raw','core','editorial','intake','ops','extensions'
      )
    )
    OR EXISTS (
      SELECT 1
      FROM pg_catalog.pg_depend AS dependency
      JOIN pg_catalog.pg_namespace AS namespace
        ON dependency.refclassid='pg_namespace'::pg_catalog.regclass
       AND dependency.refobjid=namespace.oid
      WHERE namespace.nspname='public'
        AND dependency.deptype='n'
    )
  ) THEN
    RAISE EXCEPTION 'R6E_PRE_0041_DATABASE_NOT_PRISTINE'
      USING ERRCODE='55000';
  END IF;

  SELECT count(*) INTO v_existing_role_count
  FROM pg_catalog.pg_roles
  WHERE rolname IN (
    'gurine_economics_writer',
    'gurine_payment_writer',
    'gurine_billing_gateway',
    'gurine_economics_importer'
  );

  IF v_post_0041 THEN
    IF v_existing_role_count<>4 THEN
      RAISE EXCEPTION 'R6E_POST_0041_ROLE_SET_INVALID'
        USING ERRCODE='42501';
    END IF;
  ELSIF v_existing_role_count=0 THEN
    BEGIN
      CREATE ROLE gurine_economics_writer
        NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
        NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD NULL;
      CREATE ROLE gurine_payment_writer
        NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
        NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD NULL;
      CREATE ROLE gurine_billing_gateway
        LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
        NOBYPASSRLS CONNECTION LIMIT 8 PASSWORD NULL;
      CREATE ROLE gurine_economics_importer
        LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
        NOBYPASSRLS CONNECTION LIMIT 4 PASSWORD NULL;
    EXCEPTION
      WHEN duplicate_object OR unique_violation THEN
        -- Advisory locks are database-local.  A concurrent provisioner in a
        -- second database may win the cluster-global role creation race.  The
        -- subtransaction rolls back every local CREATE before the exact
        -- cluster-wide state is re-read below; it never repairs a partial set.
        NULL;
    END;

    SELECT count(*) INTO v_existing_role_count
    FROM pg_catalog.pg_roles
    WHERE rolname IN (
      'gurine_economics_writer',
      'gurine_payment_writer',
      'gurine_billing_gateway',
      'gurine_economics_importer'
    );
    IF v_existing_role_count<>4 THEN
      RAISE EXCEPTION 'R6E_PRE_0041_ROLE_SET_PARTIAL'
        USING ERRCODE='42501';
    END IF;
  ELSIF v_existing_role_count<>4 THEN
    RAISE EXCEPTION 'R6E_PRE_0041_ROLE_SET_PARTIAL'
      USING ERRCODE='42501';
  END IF;

  FOR v_expected IN
    SELECT * FROM (VALUES
      ('gurine_economics_writer',false,-1),
      ('gurine_payment_writer',false,-1),
      ('gurine_billing_gateway',true,8),
      ('gurine_economics_importer',true,4)
    ) AS expected(role_name,can_login,connection_limit)
  LOOP
    SELECT oid INTO v_role_oid
    FROM pg_catalog.pg_roles
    WHERE rolname=v_expected.role_name;

    IF NOT FOUND OR EXISTS (
      SELECT 1
      FROM pg_catalog.pg_authid AS role_auth
      JOIN pg_catalog.pg_roles AS role_state USING (oid)
      WHERE role_state.oid=v_role_oid
        AND (
          role_state.rolsuper
          OR role_state.rolinherit
          OR role_state.rolcreaterole
          OR role_state.rolcreatedb
          OR role_state.rolreplication
          OR role_state.rolbypassrls
          OR role_state.rolcanlogin IS DISTINCT FROM v_expected.can_login
          OR role_state.rolconnlimit IS DISTINCT FROM
            v_expected.connection_limit
          OR role_auth.rolpassword IS NOT NULL
          OR role_state.rolvaliduntil IS NOT NULL
          OR role_state.rolconfig IS NOT NULL
        )
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_ATTRIBUTES_INVALID'
        USING ERRCODE='42501';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_auth_members AS membership
      WHERE membership.roleid=v_role_oid OR membership.member=v_role_oid
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_MEMBERSHIP_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_db_role_setting AS role_setting
      WHERE role_setting.setrole=v_role_oid
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_SETTING_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;

    IF v_post_0041 AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_shdepend AS dependency
      WHERE dependency.refclassid='pg_authid'::pg_catalog.regclass
        AND dependency.refobjid=v_role_oid
        AND dependency.dbid IS DISTINCT FROM v_database_oid
        AND dependency.deptype IN ('a','o')
    ) THEN
      RAISE EXCEPTION 'R6E_POST_0041_CROSS_DATABASE_AUTHORITY_FORBIDDEN'
        USING ERRCODE='42501';
    ELSIF NOT v_post_0041 AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_shdepend AS dependency
      WHERE dependency.refclassid='pg_authid'::pg_catalog.regclass
        AND dependency.refobjid=v_role_oid
        AND dependency.deptype IN ('a','o')
    ) THEN
      RAISE EXCEPTION 'R6E_PRE_0041_ROLE_AUTHORITY_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;
  END LOOP;

  IF v_post_0041 THEN
    BEGIN
      SELECT ops.assert_r6e_runtime_role_postconditions_v1()
      INTO STRICT v_postcondition;
    EXCEPTION
      WHEN undefined_function THEN
        RAISE EXCEPTION 'R6E_POST_0041_ORACLE_MISSING'
          USING ERRCODE='55000';
    END;
    IF v_postcondition IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'R6E_POST_0041_ORACLE_REJECTED'
        USING ERRCODE='55000';
    END IF;
  END IF;
END
$r6e_role_provisioning$;

COMMIT;
