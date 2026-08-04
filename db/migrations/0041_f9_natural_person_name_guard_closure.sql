BEGIN;
-- F9 forward-only natural-person publication guard closure.
-- Historical migrations and immutable v1 policy rows remain byte-preserved.
CREATE OR REPLACE FUNCTION editorial.r6d_public_slug_valid_v1(p_slug text)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,pg_temp AS $$
  SELECT char_length(p_slug) BETWEEN 1 AND 120
    AND p_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
$$;
ALTER FUNCTION editorial.r6d_public_slug_valid_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_slug_valid_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.list_r6d_invalid_public_slugs_v1()
RETURNS TABLE(case_id uuid,slug_length integer,violation_codes text[]) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,editorial,pg_temp AS $$
  SELECT cases.id,char_length(cases.public_slug),ARRAY_REMOVE(ARRAY[
    CASE WHEN char_length(cases.public_slug) NOT BETWEEN 1 AND 120
      THEN 'LENGTH_OUT_OF_RANGE' END,
    CASE WHEN cases.public_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
      THEN 'CHARACTER_SET_OR_SHAPE_INVALID' END
  ],NULL)::text[]
  FROM editorial.cases AS cases
  WHERE cases.public_slug IS NOT NULL
    AND NOT editorial.r6d_public_slug_valid_v1(cases.public_slug)
  ORDER BY cases.id
$$;
ALTER FUNCTION editorial.list_r6d_invalid_public_slugs_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.list_r6d_invalid_public_slugs_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.list_r6d_invalid_public_slugs_v1() TO gurine_control_api,gurine_auditor;
ALTER TABLE editorial.cases ADD CONSTRAINT cases_public_slug_f9_shape_ck CHECK (
    public_slug IS NULL OR (
      char_length(public_slug) BETWEEN 1 AND 120
      AND public_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    )
  ) NOT VALID;
CREATE OR REPLACE FUNCTION editorial.r6d_public_text_tree_v1(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,pg_temp AS $$
DECLARE
  v_fields jsonb; v_children jsonb; v_items jsonb;
  v_item jsonb; v_child jsonb; v_payload_item jsonb;
  v_key text; v_value jsonb; v_evidence_index integer; v_item_index integer;
  v_path text[];
BEGIN
  IF jsonb_typeof(p_payload)<>'object'
     OR jsonb_typeof(p_payload->'slug') IS DISTINCT FROM 'string'
     OR char_length(p_payload->>'slug') NOT BETWEEN 1 AND 120
     OR (p_payload->>'slug') !~ '^[a-z0-9]+(-[a-z0-9]+)*$' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
  END IF;
  v_fields:=jsonb_build_array(jsonb_build_object('name','slug','node',
    jsonb_build_object('kind','TEXT','value',p_payload->>'slug')));
  IF p_payload->>'schema_version'='1.0.0' THEN
    FOREACH v_key IN ARRAY ARRAY['title','summary','non_conclusion']
    LOOP
      IF jsonb_typeof(p_payload->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object('kind','TEXT','value',p_payload->>v_key)));
    END LOOP;
    IF jsonb_typeof(p_payload->'sections')<>'array' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'sections')
    LOOP
      IF jsonb_typeof(v_item)<>'object'
         OR jsonb_typeof(v_item->'heading')<>'string'
         OR jsonb_typeof(v_item->'blocks')<>'array' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_children:=jsonb_build_array(jsonb_build_object('name','heading','node',
        jsonb_build_object('kind','TEXT','value',v_item->>'heading')));
      v_value:='[]'::jsonb;
      FOR v_child IN SELECT value FROM jsonb_array_elements(v_item->'blocks')
      LOOP
        IF jsonb_typeof(v_child)<>'object'
           OR (v_child ? 'text' AND jsonb_typeof(v_child->'text')
               NOT IN ('string','null')) THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
        END IF;
        v_items:=CASE WHEN v_child ? 'text'
                           AND jsonb_typeof(v_child->'text')='string'
          THEN jsonb_build_array(jsonb_build_object('name','text','node',
            jsonb_build_object('kind','TEXT','value',v_child->>'text')))
          ELSE '[]'::jsonb END;
        IF v_child ? 'data' AND jsonb_typeof(v_child->'data')<>'null' THEN
          v_items:=v_items||jsonb_build_array(jsonb_build_object('name','data',
            'node',editorial.r6d_public_data_node_v1(v_child->'data')));
        END IF;
        v_value:=v_value||jsonb_build_array(
          jsonb_build_object('kind','OBJECT','items',v_items));
      END LOOP;
      v_children:=v_children||jsonb_build_array(jsonb_build_object('name','blocks',
        'node',jsonb_build_object('kind','ARRAY','items',v_value)));
      IF v_fields @> jsonb_build_array(jsonb_build_object('name','sections')) THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name','__section_pending','node',
        jsonb_build_object('kind','OBJECT','items',v_children)));
    END LOOP;
    SELECT COALESCE(jsonb_agg(value->'node' ORDER BY ordinal),'[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(v_fields) WITH ORDINALITY AS field(value,ordinal)
    WHERE value->>'name'='__section_pending';
    SELECT COALESCE(jsonb_agg(value ORDER BY ordinal),'[]'::jsonb)
    INTO v_fields
    FROM jsonb_array_elements(v_fields) WITH ORDINALITY AS field(value,ordinal)
    WHERE value->>'name'<>'__section_pending';
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object('name','sections',
      'node',jsonb_build_object('kind','ARRAY','items',v_items)));
    FOREACH v_key IN ARRAY ARRAY[
      'claims','evidence','subjects','responses','corrections'
    ] LOOP
      IF jsonb_typeof(p_payload->v_key)<>'array' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
    END LOOP;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object('name','text_ko',
        'node',jsonb_build_object('kind','TEXT','value',value->>'text_ko')))
    ) ORDER BY ordinal),'[]'::jsonb) INTO v_items
    FROM jsonb_array_elements(p_payload->'claims')
      WITH ORDINALITY item(value,ordinal)
    WHERE jsonb_typeof(value)='object'
      AND jsonb_typeof(value->'text_ko')='string';
    IF jsonb_array_length(v_items)<>jsonb_array_length(p_payload->'claims') THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
    END IF;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object('name','claims',
      'node',jsonb_build_object('kind','ARRAY','items',v_items)));
    v_fields:=v_fields||editorial.r6d_archive_public_text_tail_v1(p_payload);
    RETURN jsonb_build_object('kind','OBJECT','items',v_fields);
  END IF;

  FOREACH v_key IN ARRAY ARRAY['title','summary','nonConclusion']
  LOOP
    IF jsonb_typeof(p_payload->v_key)<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
    END IF;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object('name',v_key,'node',
      jsonb_build_object('kind','TEXT','value',p_payload->>v_key)));
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['agencyName','contractName']
  LOOP
    IF p_payload ? v_key AND jsonb_typeof(p_payload->v_key)<>'null' THEN
      IF jsonb_typeof(p_payload->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object('name',v_key,'node',
        jsonb_build_object('kind','TEXT','value',p_payload->>v_key)));
    END IF;
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['officialConfirmation','correctionNotice']
  LOOP
    IF p_payload ? v_key AND jsonb_typeof(p_payload->v_key)<>'null' THEN
      IF jsonb_typeof(p_payload->v_key)<>'object' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_children:='[]'::jsonb;
      FOR v_value IN SELECT value FROM jsonb_array_elements(
        CASE v_key WHEN 'officialConfirmation' THEN
          '["institution","documentType","confirmedScope","sourceLocator"]'::jsonb
        ELSE '["reason","impactSummary"]'::jsonb END
      ) LOOP
        IF jsonb_typeof(p_payload->v_key->(v_value#>>'{}'))<>'string' THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
        END IF;
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name',v_value#>>'{}','node',jsonb_build_object('kind','TEXT',
            'value',p_payload->v_key->>(v_value#>>'{}'))));
      END LOOP;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object('name',v_key,
        'node',jsonb_build_object('kind','OBJECT','items',v_children)));
    END IF;
  END LOOP;
  v_fields:=v_fields||editorial.r6d_current_public_text_tail_v1(p_payload);
  SELECT ordinal::integer-1 INTO STRICT v_evidence_index
  FROM jsonb_array_elements(v_fields) WITH ORDINALITY AS field(value,ordinal)
  WHERE value->>'name'='evidence';
  FOR v_payload_item,v_item_index IN
    SELECT value,ordinal::integer-1
    FROM jsonb_array_elements(p_payload->'evidence')
      WITH ORDINALITY AS item(value,ordinal)
  LOOP
    IF v_payload_item ? 'sourceUrl'
       AND jsonb_typeof(v_payload_item->'sourceUrl')<>'null' THEN
      IF jsonb_typeof(v_payload_item->'sourceUrl')<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
      END IF;
      v_path:=ARRAY[
        v_evidence_index::text,'node','items',v_item_index::text,'items'
      ];
      v_children:=v_fields#>v_path;
      v_fields:=jsonb_set(v_fields,v_path,
        v_children||jsonb_build_array(jsonb_build_object('name','sourceUrl',
          'node',jsonb_build_object('kind','TEXT',
            'value',v_payload_item->>'sourceUrl')))
      );
    END IF;
  END LOOP;
  RETURN jsonb_build_object('kind','OBJECT','items',v_fields);
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
END
$$;
ALTER FUNCTION editorial.r6d_public_text_tree_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_tree_v1(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_public_text_sha256_v1(p_payload jsonb)
RETURNS char(64) LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,extensions,pg_temp AS $$
  SELECT encode(extensions.digest(editorial.r6d_public_text_node_preimage_v1(
    editorial.r6d_public_text_tree_v1(p_payload)),'sha256'),'hex')::char(64)
$$;
ALTER FUNCTION editorial.r6d_public_text_sha256_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_sha256_v1(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_json_pointer_text_v1(
  p_document jsonb,p_pointer text
) RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,pg_temp AS $$
DECLARE
  v_current jsonb:=editorial.r6d_public_text_tree_v1(p_document);
  v_raw_segment text;
  v_segment text;
  v_index bigint;
BEGIN
  IF octet_length(convert_to(p_pointer,'UTF8')) NOT BETWEEN 1 AND 2048
     OR p_pointer !~ '^(/([^/~]|~[01])*)+$' THEN
    RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
  END IF;
  FOREACH v_raw_segment IN ARRAY string_to_array(substr(p_pointer,2),'/')
  LOOP
    v_segment:=replace(replace(v_raw_segment,'~1','/'),'~0','~');
    IF jsonb_typeof(v_current)<>'object' OR v_current->>'kind' IS NULL THEN
      RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
    END IF;
    IF v_current->>'kind'='OBJECT' THEN
      SELECT field.value->'node' INTO STRICT v_current
      FROM jsonb_array_elements(v_current->'items') AS field(value)
      WHERE field.value->>'name'=v_segment;
    ELSIF v_current->>'kind'='ARRAY' THEN
      IF v_segment !~ '^(0|[1-9][0-9]*)$' THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
      END IF;
      BEGIN
        v_index:=v_segment::bigint;
      EXCEPTION WHEN numeric_value_out_of_range THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
      END;
      IF v_index>=jsonb_array_length(v_current->'items') OR v_index>2147483647 THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
      END IF;
      v_current:=v_current->'items'->(v_index::integer);
    ELSE
      RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
    END IF;
  END LOOP;
  IF jsonb_typeof(v_current)<>'object' OR v_current->>'kind'<>'TEXT'
     OR jsonb_typeof(v_current->'value')<>'string' THEN
    RAISE EXCEPTION 'r6d_public_text_pointer_not_text' USING ERRCODE='23514';
  END IF;
  RETURN v_current->>'value';
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.r6d_json_pointer_text_v1(jsonb,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_json_pointer_text_v1(jsonb,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_public_text_leaves_f9_v1(p_node jsonb,p_pointer text)
RETURNS TABLE(json_pointer text,text_value text) LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,pg_temp AS $$
DECLARE v_entry record; v_child_pointer text;
BEGIN
  IF jsonb_typeof(p_node)<>'object' THEN
    RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
  END IF;
  IF p_node->>'kind'='TEXT' THEN
    IF jsonb_typeof(p_node->'value')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
    END IF;
    RETURN QUERY SELECT p_pointer,p_node->>'value';
  ELSIF p_node->>'kind'='ARRAY' THEN
    FOR v_entry IN SELECT value,ordinal FROM jsonb_array_elements(p_node->'items')
      WITH ORDINALITY AS item(value,ordinal)
    LOOP
      v_child_pointer:=p_pointer||'/'||(v_entry.ordinal-1)::text;
      RETURN QUERY SELECT leaf.json_pointer,leaf.text_value
      FROM editorial.r6d_public_text_leaves_f9_v1(
        v_entry.value,v_child_pointer
      ) AS leaf;
    END LOOP;
  ELSIF p_node->>'kind'='OBJECT' THEN
    FOR v_entry IN SELECT value FROM jsonb_array_elements(p_node->'items')
      AS field(value)
    LOOP
      v_child_pointer:=p_pointer||'/'||replace(replace(
        v_entry.value->>'name','~','~0'
      ),'/','~1');
      RETURN QUERY SELECT leaf.json_pointer,leaf.text_value
      FROM editorial.r6d_public_text_leaves_f9_v1(
        v_entry.value->'node',v_child_pointer
      ) AS leaf;
    END LOOP;
  ELSE
    RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
  END IF;
END
$$;
ALTER FUNCTION editorial.r6d_public_text_leaves_f9_v1(jsonb,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_leaves_f9_v1(jsonb,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_title_separator_f9_v1(p_character text)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,pg_temp AS $$
  SELECT p_character=ANY(ARRAY[
    ' ',E'\t',':',',','·','ㆍ','-','‐','‑','–','(',')','[',']','"','「','」'
  ]::text[])
$$;
ALTER FUNCTION editorial.r6d_title_separator_f9_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_title_separator_f9_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_title_tokens_f9_v1(p_text text)
RETURNS TABLE(start_character integer,end_character integer,token_text text) LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,pg_temp AS $$
DECLARE v_index integer; v_start integer; v_character text;
BEGIN
  FOR v_index IN 1..char_length(p_text) LOOP
    v_character:=substr(p_text,v_index,1);
    IF editorial.r6d_title_separator_f9_v1(v_character) THEN
      IF v_start IS NOT NULL THEN
        start_character:=v_start-1; end_character:=v_index-1;
        token_text:=substr(p_text,v_start,v_index-v_start); RETURN NEXT;
        v_start:=NULL;
      END IF;
    ELSIF v_start IS NULL THEN
      v_start:=v_index;
    END IF;
  END LOOP;
  IF v_start IS NOT NULL THEN
    start_character:=v_start-1; end_character:=char_length(p_text);
    token_text:=substr(p_text,v_start); RETURN NEXT;
  END IF;
END
$$;
ALTER FUNCTION editorial.r6d_title_tokens_f9_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_title_tokens_f9_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_title_token_f9_v1(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,pg_temp AS $$
  WITH normalized(value) AS (SELECT replace(replace(replace(
    normalize(p_value,NFKC),chr(8203),''),chr(65279),''),chr(173),''
  ))
  SELECT EXISTS(
    SELECT 1 FROM normalized
    CROSS JOIN unnest(ARRAY[
      '감사원장','국회의원','대표이사','상임감사','지방의원','교육감',
      '국무총리','기관장','대통령','부기관장','부사장','부위원장','시장',
      '실장','위원장','이사장','차관','총장','감사','과장','구청장','국장',
      '군수','담당관','도지사','대표','본부장','부장','상무','원장','이사',
      '임원','장관','전무','청장','팀장','회장','부회장','사장'
    ]::text[]) AS title(value)
    CROSS JOIN unnest(ARRAY[
      '','에게서','으로서','으로는','에게','께서','으로','라는','이라고',
      '은','는','이','가','을','를','의','와','과','께','도','만'
    ]::text[]) AS particle(value)
    WHERE normalized.value=title.value||particle.value
  )
$$;
ALTER FUNCTION editorial.r6d_title_token_f9_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_title_token_f9_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_name_prefix_characters_f9_v1(p_value text)
RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,pg_temp AS $$
DECLARE
  v_normalized text:=replace(replace(replace(
    normalize(p_value,NFKC),chr(8203),''),chr(65279),''),chr(173),'');
  v_name text; v_candidate text; v_index integer; v_prefix text;
BEGIN
  SELECT left(v_normalized,char_length(v_normalized)-char_length(particle))
  INTO v_candidate
  FROM unnest(ARRAY[
    '에게서','으로서','으로는','에게','께서','으로','라는','이라고',
    '은','는','이','가','을','를','의','와','과','께','도','만'
  ]::text[]) AS suffix(particle)
  WHERE right(v_normalized,char_length(particle))=particle
    AND char_length(v_normalized)-char_length(particle) BETWEEN 2 AND 4
  ORDER BY octet_length(left(
    v_normalized,char_length(v_normalized)-char_length(particle)
  )) DESC LIMIT 1;
  v_name:=COALESCE(v_candidate,v_normalized);
  IF v_name!~'^[가-힣]{2,4}$' THEN RETURN NULL; END IF;
  FOR v_index IN 1..char_length(p_value) LOOP
    v_prefix:=regexp_replace(translate(lower(normalize(
      substr(p_value,1,v_index),NFKC
    )),'.·ㆍ-‐‑–'||chr(8203)||chr(65279)||chr(173),''),
      '[[:space:]]','','g');
    IF v_prefix=v_name THEN RETURN v_index; END IF;
  END LOOP;
  RETURN NULL;
END
$$;
ALTER FUNCTION editorial.r6d_name_prefix_characters_f9_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_name_prefix_characters_f9_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_utf16_units_f9_v1(p_value text)
RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_units integer:=0; v_index integer;
BEGIN
  FOR v_index IN 1..char_length(p_value) LOOP
    v_units:=v_units+CASE WHEN ascii(substr(p_value,v_index,1))>65535
      THEN 2 ELSE 1 END;
  END LOOP;
  RETURN v_units;
END
$$;
ALTER FUNCTION editorial.r6d_utf16_units_f9_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_utf16_units_f9_v1(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_title_finding_f9_v1(
  p_pointer text,p_text text,p_start integer,p_length integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,extensions,pg_temp AS $$
  SELECT jsonb_build_object(
    'ordinal',0,'detectorKind','TITLE_ADJACENT_KOREAN_NAME',
    'jsonPointer',p_pointer,
    'startUtf16',editorial.r6d_utf16_units_f9_v1(left(p_text,p_start)),
    'endUtf16',editorial.r6d_utf16_units_f9_v1(left(p_text,p_start+p_length)),
    'matchedTextSha256',encode(extensions.digest(convert_to(
      substr(p_text,p_start+1,p_length),'UTF8'
    ),'sha256'),'hex'),
    'personNodeId',NULL,'topologyDigest',NULL,
    'contextId',NULL,'personNameDigest',NULL
  )
$$;
ALTER FUNCTION editorial.r6d_title_finding_f9_v1(text,text,integer,integer) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_title_finding_f9_v1(text,text,integer,integer) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.r6d_title_lower_bound_findings_f9_v1(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog,editorial,extensions,pg_temp AS $$
DECLARE
  v_findings jsonb:='[]'::jsonb; v_leaf record; v_token record;
  v_previous_start integer; v_previous_end integer; v_previous_text text;
  v_prefix integer; v_candidate jsonb; v_leaf_count integer:=0;
BEGIN
  FOR v_leaf IN SELECT * FROM editorial.r6d_public_text_leaves_f9_v1(
    editorial.r6d_public_text_tree_v1(p_payload),'') LOOP
    v_leaf_count:=v_leaf_count+1;
    IF v_leaf_count>10000 OR octet_length(convert_to(v_leaf.text_value,'UTF8'))>1048576 THEN
      RAISE EXCEPTION 'r6d_title_lower_bound_input_too_large' USING ERRCODE='22023';
    END IF;
    v_previous_start:=NULL; v_previous_end:=NULL; v_previous_text:=NULL;
    FOR v_token IN SELECT * FROM editorial.r6d_title_tokens_f9_v1(v_leaf.text_value) LOOP
      IF v_previous_start IS NOT NULL
         AND v_token.start_character-v_previous_end BETWEEN 1 AND 4 THEN
        IF editorial.r6d_title_token_f9_v1(v_previous_text) THEN
          v_prefix:=editorial.r6d_name_prefix_characters_f9_v1(v_token.token_text);
          IF v_prefix IS NOT NULL THEN
            v_candidate:=editorial.r6d_title_finding_f9_v1(
              v_leaf.json_pointer,v_leaf.text_value,v_token.start_character,v_prefix);
            IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_findings) AS f(value)
              WHERE value->>'jsonPointer'=v_candidate->>'jsonPointer'
                AND value->>'startUtf16'=v_candidate->>'startUtf16'
                AND value->>'endUtf16'=v_candidate->>'endUtf16') THEN
              v_candidate:=jsonb_set(v_candidate,'{ordinal}',
                to_jsonb(jsonb_array_length(v_findings)));
              v_findings:=v_findings||jsonb_build_array(v_candidate);
            END IF;
          END IF;
        END IF;
        IF editorial.r6d_title_token_f9_v1(v_token.token_text) THEN
          v_prefix:=editorial.r6d_name_prefix_characters_f9_v1(v_previous_text);
          IF v_prefix IS NOT NULL THEN
            v_candidate:=editorial.r6d_title_finding_f9_v1(
              v_leaf.json_pointer,v_leaf.text_value,v_previous_start,v_prefix);
            IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_findings) AS f(value)
              WHERE value->>'jsonPointer'=v_candidate->>'jsonPointer'
                AND value->>'startUtf16'=v_candidate->>'startUtf16'
                AND value->>'endUtf16'=v_candidate->>'endUtf16') THEN
              v_candidate:=jsonb_set(v_candidate,'{ordinal}',
                to_jsonb(jsonb_array_length(v_findings)));
              v_findings:=v_findings||jsonb_build_array(v_candidate);
            END IF;
          END IF;
        END IF;
      END IF;
      IF jsonb_array_length(v_findings)>10000 THEN
        RAISE EXCEPTION 'r6d_title_lower_bound_finding_limit_exceeded' USING ERRCODE='22023';
      END IF;
      v_previous_start:=v_token.start_character;
      v_previous_end:=v_token.end_character;
      v_previous_text:=v_token.token_text;
    END LOOP;
  END LOOP;
  RETURN v_findings;
END
$$;
ALTER FUNCTION editorial.r6d_title_lower_bound_findings_f9_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_title_lower_bound_findings_f9_v1(jsonb) FROM PUBLIC;
COMMENT ON FUNCTION editorial.r6d_title_lower_bound_findings_f9_v1(jsonb) IS
  'Independent TITLE_ADJACENT_KOREAN_NAME lower bound only. REGISTERED_PERSON_EXACT completeness remains outside SQL because decrypting registered names requires application-held key authority.';
ALTER TABLE editorial.named_person_publication_policies DROP CONSTRAINT named_person_publication_policies_shape_ck;
ALTER TABLE editorial.named_person_publication_policies ADD CONSTRAINT named_person_publication_policies_shape_ck CHECK (
    policy_version IN ('r6d-named-person-publication-v1','r6d-named-person-publication-v2')
    AND detector_kinds=ARRAY['REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME']::text[]
    AND override_reason_codes=ARRAY['OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE']::text[]
    AND ambiguous_match_disposition='BLOCK_HUMAN_REVIEW'
    AND convert_from(policy_canonical,'UTF8')::jsonb=policy_payload
    AND policy_digest=encode(extensions.digest(policy_canonical,'sha256'),'hex')
    AND (
      policy_version='r6d-named-person-publication-v1'
      AND policy_payload->>'policyVersion'=policy_version
      AND policy_payload->>'scannerRulesetSha256'=
        '12cef82152a675eb9a7263c8cda984faa0da1ff676b0ff614db9437cf49d30fc'
      OR policy_version='r6d-named-person-publication-v2'
      AND policy_payload->>'policyVersion'=policy_version
      AND policy_payload->>'scannerRulesetSha256'=
        '3b6449ab94c887b9b31ddb10481acfc132d4db29fcbadb394fa88c7305ec09c4'
      AND policy_payload->>'sqlLowerBound'='TITLE_ADJACENT_KOREAN_NAME_ONLY'
      AND policy_payload->>'registeredExactCompleteness'=
        'APPLICATION_KEY_REQUIRED_OUTSIDE_SQL_LOWER_BOUND'
    )
  );
WITH policy AS (
  SELECT jsonb_build_object(
    'schemaVersion','named-person-publication-policy.v2',
    'policyVersion','r6d-named-person-publication-v2',
    'scannerRulesetVersion','ko-named-individual-v1',
    'scannerRulesetSha256',
      '3b6449ab94c887b9b31ddb10481acfc132d4db29fcbadb394fa88c7305ec09c4',
    'detectors',jsonb_build_array('REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'),
    'ambiguousDisposition','BLOCK_HUMAN_REVIEW',
    'overrideReasonCodes',jsonb_build_array('OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE'),
    'legalReviewedSource','IMMUTABLE_OVERRIDE_RECEIPT_ONLY',
    'identityMergeUse','FORBIDDEN',
    'publicTextTree','SLUG_AND_EVIDENCE_SOURCE_URL_V2',
    'normalization','NFKC_IGNORABLES_V2',
    'titleAdjacency','QUOTED_SEPARATOR_V2',
    'sqlLowerBound','TITLE_ADJACENT_KOREAN_NAME_ONLY',
    'registeredExactCompleteness',
      'APPLICATION_KEY_REQUIRED_OUTSIDE_SQL_LOWER_BOUND'
  ) AS payload
), canonical AS (
  SELECT payload,ops.canonical_jsonb_v1(payload) AS bytes FROM policy
)
INSERT INTO editorial.named_person_publication_policies(
  policy_version,detector_kinds,override_reason_codes,
  ambiguous_match_disposition,active,policy_payload,policy_canonical,
  policy_digest,effective_at
)
SELECT 'r6d-named-person-publication-v2',
  ARRAY['REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME']::text[],
  ARRAY['OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE']::text[],
  'BLOCK_HUMAN_REVIEW',true,payload,bytes,
  encode(extensions.digest(bytes,'sha256'),'hex'),clock_timestamp()
FROM canonical;
CREATE OR REPLACE FUNCTION editorial.record_named_person_publication_assessment_v1(p_request jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,editorial,core,ops,extensions,pg_temp AS $$
DECLARE
  v_case editorial.cases%ROWTYPE; v_snapshot editorial.review_snapshots%ROWTYPE;
  v_policy editorial.named_person_publication_policies%ROWTYPE;
  v_existing editorial.named_person_publication_assessments%ROWTYPE;
  v_assessment_id uuid:=gen_random_uuid(); v_case_id uuid; v_snapshot_id uuid;
  v_state editorial.publication_state; v_context text; v_public_payload jsonb;
  v_scan jsonb; v_findings jsonb; v_lower_findings jsonb; v_override jsonb;
  v_actor_id uuid; v_actor_jti uuid; v_request_id uuid;
  v_idempotency char(64); v_request_digest char(64); v_public_payload_sha char(64);
  v_public_text_sha char(64); v_ruleset_version text; v_ruleset_sha char(64);
  v_registered_set_sha char(64); v_actual_registered_set_sha char(64);
  v_finding_rows jsonb:='[]'::jsonb; v_finding_set jsonb;
  v_finding_set_digest char(64); v_finding_count integer;
  v_assessment_payload jsonb; v_assessment_canonical bytea;
  v_assessment_digest char(64); v_assessment_receipt char(64);
  v_assessment_audit uuid; v_assessment_audit_digest char(64);
  v_override_result jsonb; v_now timestamptz:=clock_timestamp(); v_item jsonb;
  v_finding_payload jsonb; v_finding_canonical bytea; v_finding_digest char(64);
  v_finding_identity_digest char(64); v_ordinal integer; v_detector text;
  v_context_id uuid; v_person_node_id uuid; v_topology_digest char(64);
  v_person_name_digest char(64); v_pointer_text text; v_matched_text text;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>19
     OR NOT p_request ?& ARRAY[
       'caseId','reviewSnapshotId','publicationState','guardContext',
       'publicPayload','publicPayloadSha256','scan','legalOverride',
       '_actorId','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256',
       '_requestId','_idempotencyKeySha256','_requestSha256'
     ] THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid' USING ERRCODE='22023';
  END IF;
  BEGIN
    v_case_id:=NULLIF(p_request->>'caseId','')::uuid;
    v_snapshot_id:=NULLIF(p_request->>'reviewSnapshotId','')::uuid;
    v_state:=NULLIF(p_request->>'publicationState','')::editorial.publication_state;
    v_context:=NULLIF(p_request->>'guardContext','');
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(p_request->>'_requestSha256','')::char(64);
    v_public_payload_sha:=NULLIF(
      p_request->>'publicPayloadSha256',''
    )::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid' USING ERRCODE='22023';
  END;
  v_public_payload:=p_request->'publicPayload';
  v_scan:=p_request->'scan';
  v_override:=p_request->'legalOverride';
  IF v_case_id IS NULL OR v_snapshot_id IS NULL OR v_actor_id IS NULL
     OR v_actor_jti IS NULL OR v_request_id IS NULL
     OR v_context IS NULL
     OR v_context NOT IN ('PREVIEW','PUBLISH','CORRECTION')
     OR v_state IS NULL
     OR (v_context IN ('PREVIEW','PUBLISH') AND v_state NOT IN (
       'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
     ))
     OR (v_context='CORRECTION' AND v_state<>'CORRECTED')
     OR v_public_payload IS NULL OR jsonb_typeof(v_public_payload)<>'object'
     OR v_scan IS NULL OR jsonb_typeof(v_scan)<>'object'
     OR (v_override IS NOT NULL AND jsonb_typeof(v_override)<>'null'
         AND jsonb_typeof(v_override)<>'object')
     OR p_request->>'_actorEffectiveCapability' IS DISTINCT FROM (CASE v_context
          WHEN 'PREVIEW' THEN 'publication.preview'
          WHEN 'PUBLISH' THEN 'publication.publish'
          ELSE 'publication.correct' END)
     OR p_request->>'_actorAssuranceLevel'
          NOT IN ('ACTIVE_SESSION','RECENT_SESSION','STEP_UP')
     OR NOT ops.r6d_lower_sha256(v_public_payload_sha)
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR p_request->>'_actorRequestKeySha256' IS DISTINCT FROM v_idempotency
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM v_idempotency THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid' USING ERRCODE='22023';
  END IF;
  IF encode(extensions.digest(
       ops.canonical_jsonb_v1(v_public_payload),'sha256'
     ),'hex') IS DISTINCT FROM v_public_payload_sha THEN
    RAISE EXCEPTION 'named_person_public_payload_digest_mismatch' USING ERRCODE='23514';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_scan))<>5
     OR NOT v_scan ?& ARRAY[
       'rulesetVersion','rulesetSha256','publicTextSha256',
       'registeredNameSetSha256','findings'
     ] THEN
    RAISE EXCEPTION 'named_person_scan_shape_invalid' USING ERRCODE='22023';
  END IF;
  v_ruleset_version:=NULLIF(v_scan->>'rulesetVersion','');
  v_ruleset_sha:=NULLIF(v_scan->>'rulesetSha256','')::char(64);
  v_public_text_sha:=NULLIF(v_scan->>'publicTextSha256','')::char(64);
  v_registered_set_sha:=NULLIF(
    v_scan->>'registeredNameSetSha256',''
  )::char(64);
  v_findings:=v_scan->'findings';
  IF v_ruleset_version IS NULL OR NOT ops.r6d_lower_sha256(v_ruleset_sha)
     OR NOT ops.r6d_lower_sha256(v_public_text_sha)
     OR NOT ops.r6d_lower_sha256(v_registered_set_sha)
     OR v_findings IS NULL OR jsonb_typeof(v_findings)<>'array'
     OR jsonb_array_length(v_findings)>10000 THEN
    RAISE EXCEPTION 'named_person_scan_shape_invalid' USING ERRCODE='22023';
  END IF;
  IF editorial.r6d_public_text_sha256_v1(v_public_payload)
       IS DISTINCT FROM v_public_text_sha THEN
    RAISE EXCEPTION 'named_person_public_text_digest_mismatch' USING ERRCODE='23514';
  END IF;
  v_lower_findings:=editorial.r6d_title_lower_bound_findings_f9_v1(
    v_public_payload
  );
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_lower_findings)
  LOOP
    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(v_findings) AS finding(value)
      WHERE value->>'jsonPointer'=v_item->>'jsonPointer'
        AND value->>'startUtf16'=v_item->>'startUtf16'
        AND value->>'endUtf16'=v_item->>'endUtf16'
    ) THEN
      v_item:=jsonb_set(v_item,'{ordinal}',
        to_jsonb(jsonb_array_length(v_findings)));
      v_findings:=v_findings||jsonb_build_array(v_item);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_findings)>10000 THEN
    RAISE EXCEPTION 'named_person_scan_shape_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM editorial.named_person_publication_assessments
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.case_id IS DISTINCT FROM v_case_id
       OR v_existing.review_snapshot_id IS DISTINCT FROM v_snapshot_id
       OR v_existing.publication_state IS DISTINCT FROM v_state
       OR v_existing.guard_context IS DISTINCT FROM v_context
       OR v_existing.public_payload_sha256 IS DISTINCT FROM v_public_payload_sha
       OR v_existing.public_text_sha256 IS DISTINCT FROM v_public_text_sha
       OR v_existing.policy_version IS DISTINCT FROM
            'r6d-named-person-publication-v2'
       OR v_existing.ruleset_version IS DISTINCT FROM v_ruleset_version
       OR v_existing.ruleset_sha256 IS DISTINCT FROM v_ruleset_sha
       OR v_existing.registered_name_set_sha256
            IS DISTINCT FROM v_registered_set_sha
       OR v_existing.finding_count IS DISTINCT FROM
            jsonb_array_length(v_findings)
       OR v_existing.outcome IS DISTINCT FROM (CASE
            WHEN jsonb_array_length(v_findings)=0 THEN 'PASS' ELSE 'BLOCKED'
          END)
       OR (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'ordinal',finding.ordinal,
            'detectorKind',finding.detector_kind,
            'jsonPointer',finding.json_pointer,
            'startUtf16',finding.start_utf16,'endUtf16',finding.end_utf16,
            'matchedTextSha256',btrim(finding.matched_text_sha256),
            'personNodeId',finding.person_node_id,
            'topologyDigest',btrim(finding.topology_digest),
            'contextId',finding.context_id,
            'personNameDigest',btrim(finding.person_name_digest)
          ) ORDER BY finding.ordinal),'[]'::jsonb)
          FROM editorial.named_person_publication_findings AS finding
          WHERE finding.assessment_id=v_existing.assessment_id)
            IS DISTINCT FROM v_findings THEN
      RAISE EXCEPTION 'named_person_assessment_idempotency_conflict' USING ERRCODE='40001';
    END IF;
    v_override_result:=editorial.record_named_person_legal_override_v1(
      jsonb_build_object(
        'assessmentId',v_existing.assessment_id,
        'legalOverride',v_override,'_actorId',v_actor_id,
        '_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',
          p_request->'_actorStepUpAuthorizationId',
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    RETURN jsonb_build_object(
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'assessmentReceiptDigest',btrim(v_existing.receipt_digest),
      'assessmentAuditEventId',v_existing.audit_event_id,
      'assessmentOutcome',v_existing.outcome,
      'legalReviewRequired',v_existing.finding_count>0,
      'overrideId',v_override_result->'overrideId',
      'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
      'overrideAuditEventId',v_override_result->'overrideAuditEventId',
      'replayed',true
    );
  END IF;
  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=v_case_id FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=v_snapshot_id AND case_id=v_case_id FOR SHARE;
  IF v_case.current_review_snapshot_id IS DISTINCT FROM v_snapshot_id
     OR v_snapshot.case_version IS DISTINCT FROM v_case.version
     OR v_public_payload->>'caseId' IS DISTINCT FROM v_case_id::text
     OR v_public_payload->>'reviewSnapshotId' IS DISTINCT FROM v_snapshot_id::text
     OR v_public_payload->>'publicationState' IS DISTINCT FROM v_state::text THEN
    RAISE EXCEPTION 'named_person_assessment_scope_stale' USING ERRCODE='40001';
  END IF;
  SELECT * INTO STRICT v_policy
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v2'
    AND active AND effective_at<=v_now;
  IF v_ruleset_version IS DISTINCT FROM
       v_policy.policy_payload->>'scannerRulesetVersion'
     OR v_ruleset_sha IS DISTINCT FROM
       (v_policy.policy_payload->>'scannerRulesetSha256')::char(64) THEN
    RAISE EXCEPTION 'named_person_ruleset_authority_mismatch' USING ERRCODE='23514';
  END IF;
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_actual_registered_set_sha
  FROM (
    SELECT jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    ) AS entry,
    ops.canonical_jsonb_v1(jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    )) AS canonical
    FROM core.list_publication_person_names_v1() AS person
  ) AS registered;
  IF v_actual_registered_set_sha IS DISTINCT FROM v_registered_set_sha THEN
    RAISE EXCEPTION 'named_person_registered_set_stale' USING ERRCODE='40001';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_findings)
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_item))<>10
       OR NOT v_item ?& ARRAY[
         'ordinal','detectorKind','jsonPointer','startUtf16','endUtf16',
         'matchedTextSha256','personNodeId','topologyDigest','contextId',
         'personNameDigest'
       ] THEN
      RAISE EXCEPTION 'named_person_finding_shape_invalid' USING ERRCODE='22023';
    END IF;
    BEGIN
      v_ordinal:=NULLIF(v_item->>'ordinal','')::integer;
      v_detector:=NULLIF(v_item->>'detectorKind','');
      v_context_id:=NULLIF(v_item->>'contextId','')::uuid;
      v_person_node_id:=NULLIF(v_item->>'personNodeId','')::uuid;
      v_topology_digest:=NULLIF(v_item->>'topologyDigest','')::char(64);
      v_person_name_digest:=NULLIF(
        v_item->>'personNameDigest',''
      )::char(64);
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'named_person_finding_shape_invalid' USING ERRCODE='22023';
    END;
    IF v_ordinal IS DISTINCT FROM jsonb_array_length(v_finding_rows)
       OR v_detector NOT IN (
         'REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'
       )
       OR COALESCE(v_item->>'jsonPointer','')
            !~ '^(/([^/~]|~[01])*)+$'
       OR COALESCE(v_item->>'startUtf16','') !~ '^(0|[1-9][0-9]*)$'
       OR COALESCE(v_item->>'endUtf16','') !~ '^[1-9][0-9]*$'
       OR (v_item->>'endUtf16')::bigint<=(v_item->>'startUtf16')::bigint
       OR NOT ops.r6d_lower_sha256(v_item->>'matchedTextSha256')
       OR (
         v_detector='REGISTERED_PERSON_EXACT' AND (
           num_nonnulls(
             v_context_id,v_person_node_id,v_topology_digest,
             v_person_name_digest
           )<>4
           OR NOT ops.r6d_lower_sha256(v_topology_digest)
           OR NOT ops.r6d_lower_sha256(v_person_name_digest)
           OR NOT EXISTS(
             SELECT 1 FROM core.list_publication_person_names_v1() AS person
             WHERE person.context_id=v_context_id
               AND person.person_node_id=v_person_node_id
               AND person.topology_digest=v_topology_digest
               AND person.person_name_digest=v_person_name_digest
           )
         )
       )
       OR (
         v_detector='TITLE_ADJACENT_KOREAN_NAME'
         AND num_nonnulls(
           v_context_id,v_person_node_id,v_topology_digest,v_person_name_digest
         )<>0
       ) THEN
      RAISE EXCEPTION 'named_person_finding_binding_invalid' USING ERRCODE='23514';
    END IF;
    v_pointer_text:=editorial.r6d_json_pointer_text_v1(
      v_public_payload,v_item->>'jsonPointer'
    );
    v_matched_text:=editorial.r6d_utf16_slice_v1(
      v_pointer_text,(v_item->>'startUtf16')::integer,
      (v_item->>'endUtf16')::integer
    );
    IF encode(extensions.digest(
         convert_to(v_matched_text,'UTF8'),'sha256'
       ),'hex') IS DISTINCT FROM v_item->>'matchedTextSha256' THEN
      RAISE EXCEPTION 'named_person_finding_matched_text_digest_invalid' USING ERRCODE='23514';
    END IF;
    v_finding_payload:=jsonb_build_object(
      'schemaVersion','named-person-publication-finding.v1',
      'assessmentId',v_assessment_id,'ordinal',v_ordinal,
      'detectorKind',v_detector,'jsonPointer',v_item->>'jsonPointer',
      'startUtf16',(v_item->>'startUtf16')::integer,
      'endUtf16',(v_item->>'endUtf16')::integer,
      'matchedTextSha256',v_item->>'matchedTextSha256',
      'rulesetVersion',v_ruleset_version,
      'personBinding',CASE WHEN v_detector='REGISTERED_PERSON_EXACT'
        THEN jsonb_build_object(
          'contextId',v_context_id,'personNodeId',v_person_node_id,
          'topologyDigest',btrim(v_topology_digest),
          'personNameDigest',btrim(v_person_name_digest)
        ) ELSE NULL END
    );
    v_finding_canonical:=ops.canonical_jsonb_v1(v_finding_payload);
    v_finding_digest:=encode(
      extensions.digest(v_finding_canonical,'sha256'),'hex'
    );
    v_finding_identity_digest:=
      editorial.named_person_finding_identity_digest_v1(
        v_ordinal,v_detector,v_item->>'jsonPointer',
        (v_item->>'startUtf16')::integer,(v_item->>'endUtf16')::integer,
        v_item->>'matchedTextSha256',v_ruleset_version,v_context_id,
        v_person_node_id,btrim(v_topology_digest),btrim(v_person_name_digest)
      );
    v_finding_rows:=v_finding_rows||jsonb_build_array(jsonb_build_object(
      'payload',v_finding_payload,
      'canonical',encode(v_finding_canonical,'base64'),
      'digest',v_finding_digest,
      'identityDigest',btrim(v_finding_identity_digest)
    ));
  END LOOP;
  v_finding_count:=jsonb_array_length(v_finding_rows);
  v_finding_set:=COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'ordinal',(entry->'payload'->>'ordinal')::integer,
      'findingIdentityDigest',entry->>'identityDigest'
    ) ORDER BY (entry->'payload'->>'ordinal')::integer)
    FROM jsonb_array_elements(v_finding_rows) AS rows(entry)
  ),'[]'::jsonb);
  v_finding_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_finding_set),'sha256'
  ),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(concat_ws(':',
    v_case.id::text,v_case.version::text,v_snapshot.id::text,v_state::text,
    v_context,btrim(v_public_payload_sha),btrim(v_public_text_sha),
    btrim(v_policy.policy_digest),btrim(v_ruleset_sha),
    btrim(v_registered_set_sha)
  ),0));
  SELECT * INTO v_existing
  FROM editorial.named_person_publication_assessments AS assessment
  WHERE assessment.case_id=v_case.id
    AND assessment.case_version=v_case.version
    AND assessment.review_snapshot_id=v_snapshot.id
    AND assessment.publication_state=v_state
    AND assessment.guard_context=v_context
    AND assessment.public_payload_sha256=v_public_payload_sha
    AND assessment.public_text_sha256=v_public_text_sha
    AND assessment.policy_digest=v_policy.policy_digest
    AND assessment.ruleset_sha256=v_ruleset_sha
    AND assessment.registered_name_set_sha256=v_registered_set_sha
  FOR SHARE;
  IF FOUND THEN
    IF v_existing.review_snapshot_digest
         IS DISTINCT FROM v_snapshot.snapshot_sha256
       OR v_existing.policy_version IS DISTINCT FROM v_policy.policy_version
       OR v_existing.ruleset_version IS DISTINCT FROM v_ruleset_version
       OR v_existing.finding_count IS DISTINCT FROM v_finding_count
       OR v_existing.finding_set_digest IS DISTINCT FROM v_finding_set_digest
       OR v_existing.outcome IS DISTINCT FROM (CASE WHEN v_finding_count=0
            THEN 'PASS' ELSE 'BLOCKED' END) THEN
      RAISE EXCEPTION 'named_person_assessment_exact_binding_conflict' USING ERRCODE='40001';
    END IF;
    v_override_result:=editorial.record_named_person_legal_override_v1(
      jsonb_build_object(
        'assessmentId',v_existing.assessment_id,
        'legalOverride',v_override,'_actorId',v_actor_id,
        '_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',
          p_request->'_actorStepUpAuthorizationId',
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    RETURN jsonb_build_object(
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'assessmentReceiptDigest',btrim(v_existing.receipt_digest),
      'assessmentAuditEventId',v_existing.audit_event_id,
      'assessmentOutcome',v_existing.outcome,
      'legalReviewRequired',v_existing.finding_count>0,
      'overrideId',v_override_result->'overrideId',
      'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
      'overrideAuditEventId',v_override_result->'overrideAuditEventId',
      'replayed',true
    );
  END IF;
  v_assessment_payload:=jsonb_build_object(
    'schemaVersion','named-person-publication-assessment.v1',
    'assessmentId',v_assessment_id,'caseId',v_case.id,
    'caseVersion',v_case.version,'reviewSnapshotId',v_snapshot.id,
    'reviewSnapshotDigest',btrim(v_snapshot.snapshot_sha256),
    'publicationState',v_state,'guardContext',v_context,
    'publicPayloadSha256',btrim(v_public_payload_sha),
    'publicTextSha256',btrim(v_public_text_sha),
    'policyVersion',v_policy.policy_version,
    'policyDigest',btrim(v_policy.policy_digest),
    'rulesetVersion',v_ruleset_version,
    'rulesetSha256',btrim(v_ruleset_sha),
    'registeredNameSetSha256',btrim(v_registered_set_sha),
    'findingCount',v_finding_count,
    'findingSetDigest',btrim(v_finding_set_digest),
    'outcome',CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'requestDigest',btrim(v_request_digest),
    'evaluatedAt',v_now
  );
  v_assessment_canonical:=ops.canonical_jsonb_v1(v_assessment_payload);
  v_assessment_digest:=encode(
    extensions.digest(v_assessment_canonical,'sha256'),'hex'
  );
  v_assessment_audit:=ops.append_audit_event(
    'publication-guard:'||v_case.id::text,'SERVICE','control-api',NULL::uuid,
    'publication.named_person.assess','PublicationAssessment',
    v_assessment_id::text,
    CASE v_context WHEN 'PREVIEW' THEN 'publication.preview'
      WHEN 'PUBLISH' THEN 'publication.publish'
      ELSE 'publication.correct' END,
    'SUCCESS',NULL,v_request_id,jsonb_build_object(
      'assessmentDigest',v_assessment_digest,
      'publicPayloadSha256',btrim(v_public_payload_sha),
      'publicTextSha256',btrim(v_public_text_sha),
      'policyDigest',btrim(v_policy.policy_digest),
      'rulesetSha256',btrim(v_ruleset_sha),
      'registeredNameSetSha256',btrim(v_registered_set_sha),
      'findingCount',v_finding_count,
      'findingSetDigest',btrim(v_finding_set_digest),
      'guardContext',v_context
    )
  );
  SELECT event_hash INTO STRICT v_assessment_audit_digest
  FROM ops.audit_events WHERE id=v_assessment_audit;
  v_assessment_receipt:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','named-person-publication-assessment-receipt.v1',
      'assessmentId',v_assessment_id,
      'assessmentDigest',v_assessment_digest,
      'auditEventId',v_assessment_audit,
      'auditEventDigest',btrim(v_assessment_audit_digest),
      'requestId',v_request_id,'requestDigest',btrim(v_request_digest)
    )),'sha256'
  ),'hex');
  INSERT INTO editorial.named_person_publication_assessments(
    assessment_id,case_id,case_version,review_snapshot_id,
    review_snapshot_digest,publication_state,guard_context,
    public_payload_sha256,public_text_sha256,policy_version,policy_digest,
    ruleset_version,ruleset_sha256,registered_name_set_sha256,
    finding_count,finding_set_digest,outcome,evaluated_actor_type,
    evaluated_actor_id,request_id,idempotency_key_sha256,request_digest,
    audit_event_id,assessment_payload,assessment_canonical,
    assessment_digest,receipt_digest,evaluated_at
  ) VALUES(
    v_assessment_id,v_case.id,v_case.version,v_snapshot.id,
    v_snapshot.snapshot_sha256,v_state,v_context,v_public_payload_sha,
    v_public_text_sha,v_policy.policy_version,v_policy.policy_digest,
    v_ruleset_version,v_ruleset_sha,v_registered_set_sha,v_finding_count,
    v_finding_set_digest,
    CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'SERVICE','control-api',v_request_id,
    v_idempotency,v_request_digest,v_assessment_audit,v_assessment_payload,
    v_assessment_canonical,v_assessment_digest,v_assessment_receipt,v_now
  );
  INSERT INTO editorial.named_person_publication_findings(
    assessment_id,ordinal,detector_kind,json_pointer,start_utf16,end_utf16,
    matched_text_sha256,ruleset_version,context_id,person_node_id,
    topology_digest,person_name_digest,finding_payload,finding_canonical,
    finding_digest,finding_identity_digest
  )
  SELECT v_assessment_id,
    (entry->'payload'->>'ordinal')::integer,
    entry->'payload'->>'detectorKind',
    entry->'payload'->>'jsonPointer',
    (entry->'payload'->>'startUtf16')::integer,
    (entry->'payload'->>'endUtf16')::integer,
    (entry->'payload'->>'matchedTextSha256')::char(64),
    entry->'payload'->>'rulesetVersion',
    NULLIF(entry->'payload'->'personBinding'->>'contextId','')::uuid,
    NULLIF(entry->'payload'->'personBinding'->>'personNodeId','')::uuid,
    NULLIF(entry->'payload'->'personBinding'->>'topologyDigest','')::char(64),
    NULLIF(entry->'payload'->'personBinding'->>'personNameDigest','')::char(64),
    entry->'payload',decode(entry->>'canonical','base64'),
    (entry->>'digest')::char(64),(entry->>'identityDigest')::char(64)
  FROM jsonb_array_elements(v_finding_rows) AS rows(entry)
  ORDER BY (entry->'payload'->>'ordinal')::integer;
  v_override_result:=editorial.record_named_person_legal_override_v1(
    jsonb_build_object(
      'assessmentId',v_assessment_id,'legalOverride',v_override,
      '_actorId',v_actor_id,'_actorAssertionJti',v_actor_jti,
      '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
      '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
      '_actorActionDigest',p_request->'_actorActionDigest',
      '_actorStepUpAuthorizationId',p_request->'_actorStepUpAuthorizationId',
      '_actorIdempotencyKeySha256',
        p_request->'_actorIdempotencyKeySha256',
      '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
      '_requestId',v_request_id,
      '_idempotencyKeySha256',btrim(v_idempotency),
      '_requestSha256',btrim(v_request_digest)
    )
  );
  RETURN jsonb_build_object(
    'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'assessmentReceiptDigest',btrim(v_assessment_receipt),
    'assessmentAuditEventId',v_assessment_audit,
    'assessmentOutcome',CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'legalReviewRequired',v_finding_count>0,
    'overrideId',v_override_result->'overrideId',
    'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
    'overrideAuditEventId',v_override_result->'overrideAuditEventId',
    'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'named_person_assessment_authority_missing_or_ambiguous' USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb) TO gurine_control_api;
CREATE OR REPLACE FUNCTION editorial.assert_r6d_publication_guard_v2(
  p_case_id uuid,p_review_snapshot_id uuid,
  p_publication_state editorial.publication_state,p_public_payload jsonb,
  p_public_payload_sha256 char(64),p_guard_context text
) RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,editorial,core,ops,extensions,pg_temp AS $$
DECLARE
  v_case editorial.cases%ROWTYPE; v_snapshot editorial.review_snapshots%ROWTYPE;
  v_policy editorial.named_person_publication_policies%ROWTYPE;
  v_assessment editorial.named_person_publication_assessments%ROWTYPE;
  v_digest char(64); v_finding_count bigint; v_finding_set char(64);
  v_registered_name_set_sha256 char(64);
BEGIN
  IF p_case_id IS NULL OR p_review_snapshot_id IS NULL
     OR p_publication_state IS NULL OR p_public_payload IS NULL
     OR jsonb_typeof(p_public_payload)<>'object'
     OR p_guard_context NOT IN ('PREVIEW','PUBLISH','CORRECTION')
     OR (p_guard_context IN ('PREVIEW','PUBLISH')
       AND p_publication_state NOT IN (
         'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
       ))
     OR (p_guard_context='CORRECTION'
       AND p_publication_state<>'CORRECTED')
     OR NOT ops.r6d_lower_sha256(p_public_payload_sha256) THEN
    RAISE EXCEPTION 'r6d_publication_guard_input_invalid' USING ERRCODE='22023';
  END IF;
  v_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(p_public_payload),'sha256'
  ),'hex');
  IF v_digest IS DISTINCT FROM p_public_payload_sha256 THEN
    RAISE EXCEPTION 'r6d_publication_payload_digest_mismatch' USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=p_case_id FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=p_review_snapshot_id AND case_id=p_case_id FOR SHARE;
  IF v_case.current_review_snapshot_id IS DISTINCT FROM p_review_snapshot_id
     OR v_snapshot.case_version IS DISTINCT FROM v_case.version THEN
    RAISE EXCEPTION 'r6d_publication_snapshot_not_current' USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_policy
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v2' AND active
    AND effective_at<=clock_timestamp();
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_registered_name_set_sha256
  FROM (
    SELECT jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    ) AS entry,
    ops.canonical_jsonb_v1(jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    )) AS canonical
    FROM core.list_publication_person_names_v1() AS person
  ) AS registered;
  SELECT * INTO v_assessment
  FROM editorial.named_person_publication_assessments AS assessment
  WHERE assessment.case_id=p_case_id
    AND assessment.case_version=v_case.version
    AND assessment.review_snapshot_id=p_review_snapshot_id
    AND assessment.review_snapshot_digest=v_snapshot.snapshot_sha256
    AND assessment.publication_state=p_publication_state
    AND assessment.guard_context=p_guard_context
    AND assessment.public_payload_sha256=v_digest
    AND assessment.policy_version=v_policy.policy_version
    AND assessment.policy_digest=v_policy.policy_digest
    AND assessment.ruleset_version=
      v_policy.policy_payload->>'scannerRulesetVersion'
    AND assessment.ruleset_sha256=
      (v_policy.policy_payload->>'scannerRulesetSha256')::char(64)
    AND assessment.registered_name_set_sha256=
      v_registered_name_set_sha256
    AND assessment.outcome=CASE WHEN assessment.finding_count=0
      THEN 'PASS' ELSE 'BLOCKED' END
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_named_person_assessment_missing_or_blocked' USING ERRCODE='23514';
  END IF;
  SELECT count(*),encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(jsonb_build_object(
      'ordinal',finding.ordinal,
      'findingIdentityDigest',btrim(finding.finding_identity_digest)
    ) ORDER BY finding.ordinal),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_finding_count,v_finding_set
  FROM editorial.named_person_publication_findings AS finding
  WHERE finding.assessment_id=v_assessment.assessment_id;
  IF v_finding_count IS DISTINCT FROM v_assessment.finding_count
     OR v_finding_set IS DISTINCT FROM v_assessment.finding_set_digest THEN
    RAISE EXCEPTION 'r6d_named_person_finding_set_mismatch' USING ERRCODE='23514';
  END IF;
  IF p_guard_context='PUBLISH' AND NOT EXISTS(
    SELECT 1
    FROM editorial.named_person_publication_assessments AS source
    JOIN editorial.publication_preview_owner_receipts_v2 AS receipt
      ON receipt.assessment_id=source.assessment_id
      AND receipt.case_id=source.case_id
      AND receipt.case_version=source.case_version
      AND receipt.review_snapshot_id=source.review_snapshot_id
      AND receipt.public_payload_sha256=source.public_payload_sha256
      AND receipt.assessment_digest=source.assessment_digest
      AND receipt.assessment_receipt_digest=source.receipt_digest
    JOIN editorial.publication_previews AS preview
      ON preview.id=receipt.preview_id
      AND preview.case_id=source.case_id
      AND preview.review_snapshot_id=source.review_snapshot_id
      AND preview.preview_sha256=source.public_payload_sha256
      AND preview.preview_payload=p_public_payload
      AND preview.expires_at>clock_timestamp()
    WHERE source.case_id=v_assessment.case_id
      AND source.case_version=v_assessment.case_version
      AND source.review_snapshot_id=v_assessment.review_snapshot_id
      AND source.review_snapshot_digest=v_assessment.review_snapshot_digest
      AND source.publication_state=v_assessment.publication_state
      AND source.guard_context='PREVIEW'
      AND source.public_payload_sha256=v_assessment.public_payload_sha256
      AND source.public_text_sha256=v_assessment.public_text_sha256
      AND source.policy_version=v_assessment.policy_version
      AND source.policy_digest=v_assessment.policy_digest
      AND source.ruleset_version=v_assessment.ruleset_version
      AND source.ruleset_sha256=v_assessment.ruleset_sha256
      AND source.registered_name_set_sha256=
        v_assessment.registered_name_set_sha256
      AND source.finding_count=v_assessment.finding_count
      AND source.finding_set_digest=v_assessment.finding_set_digest
      AND source.outcome=v_assessment.outcome
  ) THEN
    RAISE EXCEPTION 'r6d_publish_preview_assessment_not_exact_or_expired' USING ERRCODE='23514';
  END IF;
  IF p_guard_context IN ('PUBLISH','CORRECTION') AND NOT EXISTS(
    SELECT 1
    FROM editorial.review_decisions AS decision
    JOIN editorial.named_person_review_stage_receipts_v1 AS stage
      ON stage.decision_id=decision.id
      AND stage.review_snapshot_id=v_assessment.review_snapshot_id
      AND stage.case_id=v_assessment.case_id
      AND stage.case_version=v_assessment.case_version
      AND stage.review_stage='EDITORIAL'
      AND stage.decision='APPROVE'
      AND stage.reviewer_user_id=decision.reviewer_id
      AND stage.decision_digest=
        editorial.review_decision_digest_v1(decision.id)
      AND stage.assurance_level='STEP_UP'
      AND stage.effective_capability='review.editorial'
    JOIN editorial.review_assignments AS assignment
      ON assignment.id=stage.review_assignment_id
      AND assignment.case_id=stage.case_id
      AND assignment.review_snapshot_id=stage.review_snapshot_id
      AND assignment.reviewer_id=stage.reviewer_user_id
      AND assignment.status='COMPLETED'
      AND assignment.completed_at IS NOT NULL
      AND assignment.version=stage.review_assignment_version_after
    JOIN ops.outbox AS outbox ON outbox.id=stage.outbox_event_id
      AND outbox.event_type='review.decision_submitted.v1'
      AND outbox.aggregate_type='ReviewDecision'
      AND outbox.aggregate_id=stage.decision_id::text
      AND outbox.aggregate_version=1
    WHERE decision.review_snapshot_id=v_assessment.review_snapshot_id
      AND decision.decision='APPROVE'
      AND decision.reviewer_id<>v_snapshot.created_by
      AND jsonb_typeof(decision.criteria)='object'
      AND NOT (decision.criteria ? 'namedIndividualOverride')
      AND stage.receipt_payload->>'decisionDigest'=
        btrim(stage.decision_digest)
      AND stage.receipt_payload->>'reviewerAuthorityDigest'=
        btrim(stage.reviewer_authority_digest)
      AND stage.receipt_payload->>'outboxEventDigest'=
        btrim(stage.outbox_event_digest)
      AND stage.outbox_event_digest=
        ops.r6d_outbox_envelope_digest_v1(outbox.id)
  ) THEN
    RAISE EXCEPTION 'r6d_independent_editorial_review_required' USING ERRCODE='23514';
  END IF;
  IF v_finding_count>0 AND p_guard_context<>'PREVIEW' AND NOT EXISTS(
    SELECT 1
    FROM editorial.named_person_publication_assessments AS source
    JOIN editorial.named_person_legal_overrides AS override
      ON override.assessment_id=source.assessment_id
      AND override.public_text_sha256=source.public_text_sha256
      AND override.ruleset_version=source.ruleset_version
    JOIN editorial.review_snapshots AS source_snapshot
      ON source_snapshot.id=source.review_snapshot_id
      AND source_snapshot.case_id=source.case_id
    JOIN editorial.review_decisions AS decision
      ON decision.id=override.editorial_review_decision_id
      AND decision.review_snapshot_id=source.review_snapshot_id
      AND decision.decision='APPROVE'
      AND decision.reviewer_id=override.editorial_reviewer_user_id
      AND jsonb_typeof(decision.criteria)='object'
      AND NOT (decision.criteria ? 'namedIndividualOverride')
    JOIN editorial.named_person_review_stage_receipts_v1 AS editorial_stage
      ON editorial_stage.receipt_id=
        override.editorial_review_stage_receipt_id
      AND editorial_stage.decision_id=decision.id
      AND editorial_stage.review_snapshot_id=source.review_snapshot_id
      AND editorial_stage.case_id=source.case_id
      AND editorial_stage.case_version=source.case_version
      AND editorial_stage.review_stage='EDITORIAL'
      AND editorial_stage.decision='APPROVE'
      AND editorial_stage.reviewer_user_id=decision.reviewer_id
      AND editorial_stage.receipt_digest=
        override.editorial_review_stage_receipt_digest
    JOIN editorial.review_decisions AS legal_decision
      ON legal_decision.review_snapshot_id=source.review_snapshot_id
      AND legal_decision.reviewer_id=override.legal_reviewer_user_id
      AND legal_decision.decision='APPROVE'
      AND jsonb_typeof(legal_decision.criteria)='object'
      AND jsonb_typeof(
        legal_decision.criteria->'namedIndividualOverride'
      )='object'
    JOIN editorial.named_person_review_stage_receipts_v1 AS legal_stage
      ON legal_stage.decision_id=legal_decision.id
      AND legal_stage.review_snapshot_id=source.review_snapshot_id
      AND legal_stage.case_id=source.case_id
      AND legal_stage.case_version=source.case_version
      AND legal_stage.review_stage='LEGAL'
      AND legal_stage.decision='APPROVE'
      AND legal_stage.reviewer_user_id=legal_decision.reviewer_id
      AND legal_stage.decision_digest=
        editorial.review_decision_digest_v1(legal_decision.id)
      AND legal_stage.actor_assertion_jti=override.actor_assertion_jti
      AND legal_stage.step_up_authorization_id=
        override.step_up_authorization_id
      AND legal_stage.step_up_receipt_digest=override.step_up_receipt_digest
      AND legal_stage.referenced_editorial_decision_id=decision.id
      AND legal_stage.referenced_editorial_stage_receipt_id=
        editorial_stage.receipt_id
      AND legal_stage.referenced_editorial_stage_receipt_digest=
        editorial_stage.receipt_digest
      AND legal_stage.named_person_override_id=override.override_id
      AND legal_stage.named_person_override_digest=override.override_digest
    WHERE source.outcome=CASE WHEN source.finding_count=0
      THEN 'PASS' ELSE 'BLOCKED' END
      AND source.case_id=v_assessment.case_id
      AND source.case_version=v_assessment.case_version
      AND source.review_snapshot_id=v_assessment.review_snapshot_id
      AND source.review_snapshot_digest=v_assessment.review_snapshot_digest
      AND source.publication_state=v_assessment.publication_state
      AND source.public_payload_sha256=v_assessment.public_payload_sha256
      AND source.public_text_sha256=v_assessment.public_text_sha256
      AND source.policy_version=v_assessment.policy_version
      AND source.policy_digest=v_assessment.policy_digest
      AND source.ruleset_version=v_assessment.ruleset_version
      AND source.ruleset_sha256=v_assessment.ruleset_sha256
      AND source.registered_name_set_sha256=
        v_assessment.registered_name_set_sha256
      AND source.finding_count=v_assessment.finding_count
      AND source.finding_set_digest=v_assessment.finding_set_digest
      AND (
        (
          p_guard_context IN ('PREVIEW','CORRECTION')
          AND source.assessment_id=v_assessment.assessment_id
          AND source.guard_context=p_guard_context
        )
        OR (
          p_guard_context='PUBLISH' AND source.guard_context='PREVIEW'
        )
      )
      AND override.publication_author_user_id=source_snapshot.created_by
      AND override.legal_reviewer_user_id<>source_snapshot.created_by
      AND override.legal_reviewer_user_id<>decision.reviewer_id
      AND decision.reviewer_id<>source_snapshot.created_by
      AND decision.created_at<override.reviewed_at
      AND legal_decision.created_at>=override.reviewed_at
      AND (SELECT count(*) FROM jsonb_object_keys(
        legal_decision.criteria->'namedIndividualOverride'
      ))=5
      AND legal_decision.criteria->'namedIndividualOverride' ?& ARRAY[
        'publicTextSha256','reasonCode','officialSourceLocator',
        'officialSourceSha256','editorialReviewDecisionId'
      ]
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'publicTextSha256'=btrim(override.public_text_sha256)
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'reasonCode'=override.reason_code
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'officialSourceLocator'=override.official_source_locator
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'officialSourceSha256'=btrim(override.official_source_sha256)
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'editorialReviewDecisionId'=decision.id::text
      AND override.editorial_review_decision_digest=
        editorial.review_decision_digest_v1(decision.id)
      AND editorial_stage.decision_digest=
        override.editorial_review_decision_digest
      AND editorial_stage.assurance_level='STEP_UP'
      AND editorial_stage.effective_capability='review.editorial'
      AND legal_stage.assurance_level='STEP_UP'
      AND legal_stage.effective_capability='review.legal'
      AND editorial_stage.reviewer_authority_digest=
        override.editorial_reviewer_authority_digest
      AND legal_stage.reviewer_authority_digest=
        override.legal_reviewer_authority_digest
      AND override.override_payload->>'policyReceiptDigest'=
        editorial.named_person_legal_override_digest_v1(
          btrim(override.public_text_sha256),override.ruleset_version,
          override.reason_code,override.official_source_locator,
          btrim(override.official_source_sha256),
          override.legal_reviewer_user_id::text
        )
  ) THEN
    RAISE EXCEPTION 'r6d_named_person_legal_override_required' USING ERRCODE='23514';
  END IF;
  IF p_publication_state='OFFICIALLY_CONFIRMED'
     AND NOT editorial.official_confirmation_valid_v1(
       p_public_payload->'officialConfirmation'
     ) THEN
    RAISE EXCEPTION 'r6d_official_confirmation_required' USING ERRCODE='23514';
  END IF;
  IF p_publication_state<>'OFFICIALLY_CONFIRMED'
     AND p_public_payload ? 'officialConfirmation' THEN
    RAISE EXCEPTION 'r6d_official_confirmation_forbidden' USING ERRCODE='23514';
  END IF;
  IF p_publication_state='CORRECTED'
     AND NOT editorial.correction_notice_valid_v1(
       p_public_payload->'correctionNotice'
     ) THEN
    RAISE EXCEPTION 'r6d_correction_notice_required' USING ERRCODE='23514';
  END IF;
  IF p_publication_state<>'CORRECTED'
     AND p_public_payload ? 'correctionNotice' THEN
    RAISE EXCEPTION 'r6d_correction_notice_forbidden' USING ERRCODE='23514';
  END IF;
  RETURN v_assessment.assessment_id;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_publication_guard_authority_missing_or_ambiguous' USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.assert_r6d_publication_guard_v2(uuid,uuid,editorial.publication_state,jsonb,char(64),text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.assert_r6d_publication_guard_v2(uuid,uuid,editorial.publication_state,jsonb,char(64),text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.assert_r6d_publication_guard_v2(uuid,uuid,editorial.publication_state,jsonb,char(64),text) TO gurine_control_api;
CREATE OR REPLACE FUNCTION editorial.guard_r6d_case_publication_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,editorial,pg_temp AS $$
DECLARE v_receipt_id uuid;
BEGIN
  IF (NEW.publication_state IS DISTINCT FROM OLD.publication_state
    OR NEW.current_publication_revision IS DISTINCT FROM
      OLD.current_publication_revision
    OR NEW.public_slug IS DISTINCT FROM OLD.public_slug
  ) AND NEW.public_slug IS NOT NULL
    AND editorial.r6d_public_slug_valid_v1(NEW.public_slug) IS NOT TRUE THEN
    RAISE EXCEPTION 'r6d_public_slug_invalid' USING ERRCODE='23514';
  END IF;
  IF NEW.publication_state IS NOT DISTINCT FROM OLD.publication_state
     AND NEW.current_publication_revision IS NOT DISTINCT FROM
       OLD.current_publication_revision
     AND NEW.public_slug IS NOT DISTINCT FROM OLD.public_slug THEN
    RETURN NEW;
  END IF;
  SELECT receipt.receipt_id INTO STRICT v_receipt_id
  FROM editorial.publication_revision_owner_receipts_v2 AS receipt
  WHERE receipt.case_id=NEW.id
    AND receipt.prior_case_version=OLD.version
    AND receipt.case_version=NEW.version
    AND receipt.publication_state=NEW.publication_state
    AND receipt.revision=NEW.current_publication_revision
    AND receipt.review_snapshot_id=NEW.current_review_snapshot_id
    AND NEW.version=OLD.version+1
    AND ROW(NEW.id,NEW.public_slug,NEW.title,NEW.investigation_state,
      NEW.resolution_code,NEW.summary,NEW.priority,NEW.lead_investigator_id,
      NEW.editor_id,NEW.legal_review_required,NEW.current_review_snapshot_id,
      NEW.created_at) IS NOT DISTINCT FROM ROW(
      OLD.id,OLD.public_slug,OLD.title,OLD.investigation_state,
      OLD.resolution_code,OLD.summary,OLD.priority,OLD.lead_investigator_id,
      OLD.editor_id,OLD.legal_review_required,OLD.current_review_snapshot_id,
      OLD.created_at)
  FOR SHARE OF receipt;
  RETURN NEW;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_case_publication_owner_required' USING ERRCODE='42501';
END
$$;
ALTER FUNCTION editorial.guard_r6d_case_publication_v2() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_r6d_case_publication_v2() FROM PUBLIC;
DROP TRIGGER cases_r6d_publication_guard ON editorial.cases;
CREATE TRIGGER cases_r6d_publication_guard
  BEFORE UPDATE ON editorial.cases
  FOR EACH ROW EXECUTE FUNCTION editorial.guard_r6d_case_publication_v2();
COMMIT;
