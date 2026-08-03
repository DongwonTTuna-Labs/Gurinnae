ALTER TABLE core.agencies
  ADD COLUMN sido_code char(2),
  ADD COLUMN sigungu_code char(5),
  ADD COLUMN region_code_version text,
  ADD CONSTRAINT core_agencies_region_codes_ck CHECK (
    (
      sido_code IS NULL
      AND sigungu_code IS NULL
      AND region_code_version IS NULL
    )
    OR (
      sido_code IS NOT NULL
      AND sigungu_code IS NOT NULL
      AND region_code_version IS NOT NULL
      AND sido_code ~ '^[0-9]{2}$'
      AND sigungu_code ~ '^[0-9]{5}$'
      AND left(sigungu_code::text, 2) = sido_code::text
      AND nullif(btrim(region_code_version), '') IS NOT NULL
    )
  );

-- REGION delivery matching needs only the agency key and its district code.
-- Keep the notification worker outside every other core agency column.
GRANT USAGE ON SCHEMA core TO gurine_notification_worker;
GRANT SELECT (id, sigungu_code) ON core.agencies TO gurine_notification_worker;

ALTER TABLE public.agencies
  ADD COLUMN sido_code char(2),
  ADD COLUMN sigungu_code char(5),
  ADD COLUMN region_code_version text,
  ADD CONSTRAINT public_agencies_region_codes_ck CHECK (
    (
      sido_code IS NULL
      AND sigungu_code IS NULL
      AND region_code_version IS NULL
    )
    OR (
      sido_code IS NOT NULL
      AND sigungu_code IS NOT NULL
      AND region_code_version IS NOT NULL
      AND sido_code ~ '^[0-9]{2}$'
      AND sigungu_code ~ '^[0-9]{5}$'
      AND left(sigungu_code::text, 2) = sido_code::text
      AND nullif(btrim(region_code_version), '') IS NOT NULL
    )
  );

ALTER TABLE editorial.evidence
  ADD COLUMN document_title text,
  ADD COLUMN publisher text,
  ADD COLUMN published_at timestamptz,
  ADD COLUMN page_anchor text;

-- The correction-session boundary is SECURITY DEFINER-owned by
-- gurine_migrator.  It already has USAGE on public and access to public.cases;
-- grant only the additional revision lookup needed to validate the exact pair.
-- PostgreSQL requires UPDATE on at least one column for FOR KEY SHARE.  The
-- owner is NOLOGIN and not granted to runtime roles, so limit that lock
-- qualification to the immutable key column instead of table-wide UPDATE.
GRANT SELECT ON public.case_revisions TO gurine_migrator;
GRANT UPDATE (case_id) ON public.case_revisions TO gurine_migrator;

-- The replacement function is owned by the NOLOGIN boundary role, while the
-- two legacy tables remain owned by the migration executor.  Give the boundary
-- only the columns written by this initial session creation.  The draft table's
-- token-scoped RLS also needs explicit INSERT and RETURNING policies because a
-- newly created draft intentionally stores no raw token hash.
GRANT INSERT (
  id, token_hash, version, case_slug, publication_revision, expires_at
) ON intake.correction_request_drafts TO gurine_migrator;
GRANT SELECT (version) ON intake.correction_request_drafts TO gurine_migrator;
GRANT INSERT (
  token_hash, session_kind, scope_type, scope_id, bff_issuer, expires_at
) ON intake.submission_sessions TO gurine_migrator;

CREATE POLICY correction_drafts_session_boundary_insert
ON intake.correction_request_drafts
FOR INSERT TO gurine_migrator
WITH CHECK (
  token_hash IS NULL
  AND version = 1
  AND (case_slug IS NULL) = (publication_revision IS NULL)
  AND requester_type IS NULL
  AND contact_email_hash IS NULL
  AND contact_email_encrypted IS NULL
  AND summary IS NULL
  AND requested_changes = '[]'::jsonb
  AND evidence_description IS NULL
);

CREATE POLICY correction_drafts_session_boundary_returning
ON intake.correction_request_drafts
FOR SELECT TO gurine_migrator
USING (
  token_hash IS NULL
  AND version = 1
  AND (case_slug IS NULL) = (publication_revision IS NULL)
  AND requester_type IS NULL
  AND contact_email_hash IS NULL
  AND contact_email_encrypted IS NULL
  AND summary IS NULL
  AND requested_changes = '[]'::jsonb
  AND evidence_description IS NULL
);

CREATE OR REPLACE FUNCTION intake.create_correction_session(
  p_session_token_hash char(64),
  p_bff_issuer text,
  p_locale text,
  p_case_slug text,
  p_publication_revision integer,
  p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid, session_id uuid, version bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE
  v_hash text := btrim(p_session_token_hash::text);
BEGIN
  IF (p_case_slug IS NULL) <> (p_publication_revision IS NULL) THEN
    RAISE EXCEPTION 'correction_publication_binding_requires_pair'
      USING ERRCODE = '22023';
  END IF;

  IF p_case_slug IS NOT NULL THEN
    PERFORM 1
    FROM public.cases AS public_case
    JOIN public.case_revisions AS public_revision
      ON public_revision.case_id = public_case.id
      AND public_revision.revision = p_publication_revision
    WHERE public_case.slug = p_case_slug
    FOR KEY SHARE OF public_case, public_revision;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'correction_publication_binding_not_found'
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  draft_id := (
    substr(v_hash, 1, 8)
    || '-'
    || substr(v_hash, 9, 4)
    || '-4'
    || substr(v_hash, 14, 3)
    || '-8'
    || substr(v_hash, 18, 3)
    || '-'
    || substr(v_hash, 21, 12)
  )::uuid;
  INSERT INTO intake.correction_request_drafts(
    id,
    token_hash,
    version,
    case_slug,
    publication_revision,
    expires_at
  ) VALUES (
    draft_id,
    NULL,
    1,
    p_case_slug,
    p_publication_revision,
    p_expires_at
  )
  RETURNING correction_request_drafts.version INTO version;
  INSERT INTO intake.submission_sessions(
    token_hash,
    session_kind,
    scope_type,
    scope_id,
    bff_issuer,
    expires_at
  ) VALUES (
    p_session_token_hash,
    'CORRECTION_DRAFT',
    'CORRECTION_DRAFT',
    draft_id,
    p_bff_issuer,
    p_expires_at
  )
  RETURNING id INTO session_id;
  RETURN NEXT;
END
$$;

ALTER FUNCTION intake.create_correction_session(
  char(64), text, text, text, integer, timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.create_correction_session(
  char(64), text, text, text, integer, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.create_correction_session(
  char(64), text, text, text, integer, timestamptz
) TO gurine_submission_api;
