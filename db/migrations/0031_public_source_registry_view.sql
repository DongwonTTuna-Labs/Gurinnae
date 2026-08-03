CREATE VIEW public.source_official_urls WITH (security_barrier = true) AS
SELECT
  source_id,
  CASE
    WHEN base_url ~* '^https?://' THEN base_url
    ELSE NULL
  END AS official_url
FROM ops.source_registry;

ALTER VIEW public.source_official_urls OWNER TO gurine_migrator;
REVOKE ALL ON TABLE public.source_official_urls FROM PUBLIC;
GRANT SELECT ON TABLE public.source_official_urls TO gurine_public_api;
