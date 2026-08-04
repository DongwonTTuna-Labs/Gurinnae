BEGIN;

-- F3 closes the official-source URL boundary at the view that grants public access.
CREATE OR REPLACE VIEW public.source_official_urls
WITH (security_barrier = true) AS
SELECT
  source.source_id,
  CASE
    WHEN source.base_url ~* '^https?://' THEN source.base_url
    ELSE NULL
  END AS official_url
FROM ops.source_registry AS source
WHERE source.enabled
  AND source.legal_status = 'APPROVED';

ALTER VIEW public.source_official_urls OWNER TO gurine_migrator;
REVOKE ALL ON TABLE public.source_official_urls FROM PUBLIC;
GRANT SELECT ON TABLE public.source_official_urls TO gurine_public_api;

-- Include the optional archive evidence source URL in the canonical public-text tree.
CREATE OR REPLACE FUNCTION editorial.r6d_archive_public_text_tail_v1(
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_fields jsonb:='[]'::jsonb;
  v_items jsonb;
  v_children jsonb;
  v_item jsonb;
  v_value jsonb;
  v_key text;
BEGIN
  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'evidence')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'summary')<>'string'
       OR jsonb_typeof(v_item->'source')<>'object'
       OR jsonb_typeof(v_item->'source'->'locator')<>'object'
       OR jsonb_typeof(v_item->'source'->'locator'->'value')<>'string'
       OR (v_item ? 'public_excerpt'
           AND jsonb_typeof(v_item->'public_excerpt') NOT IN ('string','null'))
       OR (v_item->'source' ? 'source_url'
           AND jsonb_typeof(v_item->'source'->'source_url')
             NOT IN ('string','null'))
    THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:=jsonb_build_array(jsonb_build_object(
      'name','summary','node',jsonb_build_object(
        'kind','TEXT','value',v_item->>'summary'
      )
    ));
    IF jsonb_typeof(v_item->'public_excerpt')='string' THEN
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name','public_excerpt','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'public_excerpt'
        )
      ));
    END IF;
    IF jsonb_typeof(v_item->'source'->'source_url')='string' THEN
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name','source','node',jsonb_build_object(
          'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
            'name','source_url','node',jsonb_build_object(
              'kind','TEXT','value',v_item->'source'->>'source_url'
            )
          ))
        )
      ));
    END IF;
    v_children:=v_children||jsonb_build_array(jsonb_build_object(
      'name','source_locator','node',jsonb_build_object(
        'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
          'name','value','node',jsonb_build_object(
            'kind','TEXT','value',v_item->'source'->'locator'->>'value'
          )
        ))
      )
    ));
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',v_children
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','evidence','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'subjects')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'display_name')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
        'name','display_name','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'display_name'
        )
      ))
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','subjects','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  IF jsonb_typeof(p_payload->'methodology')<>'object'
     OR NOT (p_payload->'methodology' ? 'calculation')
     OR jsonb_typeof(p_payload->'methodology'->'limitations')<>'array' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  v_children:=jsonb_build_array(
    jsonb_build_object('name','limitations','node',
      editorial.r6d_text_array_node_v1(
        p_payload->'methodology'->'limitations'
      )),
    jsonb_build_object('name','calculation','node',
      editorial.r6d_public_data_node_v1(
        p_payload->'methodology'->'calculation'
      ))
  );
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','methodology','node',jsonb_build_object(
      'kind','OBJECT','items',v_children
    )
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'responses')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'party')<>'string'
       OR jsonb_typeof(v_item->'display_text')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(
        jsonb_build_object('name','party','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'party'
        )),
        jsonb_build_object('name','display_text','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'display_text'
        ))
      )
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','responses','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'corrections')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'summary')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
        'name','summary','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'summary'
        )
      ))
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','corrections','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  IF p_payload ? 'official_confirmation' THEN
    IF jsonb_typeof(p_payload->'official_confirmation')<>'object' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:='[]'::jsonb;
    FOREACH v_key IN ARRAY ARRAY[
      'institution','document_type','confirmed_scope','source_locator'
    ] LOOP
      IF jsonb_typeof(p_payload->'official_confirmation'->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','TEXT','value',p_payload->'official_confirmation'->>v_key
        )
      ));
    END LOOP;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name','official_confirmation','node',jsonb_build_object(
        'kind','OBJECT','items',v_children
      )
    ));
  END IF;
  FOREACH v_key IN ARRAY ARRAY['correction_notice','correction_details']
  LOOP
    IF p_payload ? v_key THEN
      IF jsonb_typeof(p_payload->v_key)<>'object' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:='[]'::jsonb;
      FOR v_value IN SELECT value FROM jsonb_array_elements(
        CASE v_key WHEN 'correction_notice' THEN
          '["reason","impact_summary"]'::jsonb
        ELSE '["effective_reason"]'::jsonb END
      ) LOOP
        IF jsonb_typeof(p_payload->v_key->(v_value#>>'{}'))<>'string' THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
            USING ERRCODE='22023';
        END IF;
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name',v_value#>>'{}','node',jsonb_build_object(
            'kind','TEXT','value',p_payload->v_key->>(v_value#>>'{}')
          )
        ));
      END LOOP;
      IF v_key='correction_details' THEN
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name','limitations','node',editorial.r6d_text_array_node_v1(
            p_payload->v_key->'limitations'
          )
        ));
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','OBJECT','items',v_children
        )
      ));
    END IF;
  END LOOP;
  RETURN v_fields;
END
$$;
ALTER FUNCTION editorial.r6d_archive_public_text_tail_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_archive_public_text_tail_v1(jsonb)
  FROM PUBLIC;

COMMIT;
