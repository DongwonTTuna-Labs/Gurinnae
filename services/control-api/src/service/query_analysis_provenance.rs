use super::*;

struct GraphState {
    nodes: Vec<Value>,
    edges: Vec<Value>,
    accessible: Vec<Value>,
    ordinal: i64,
}

impl GraphState {
    fn new(root: Value) -> Self {
        Self {
            nodes: vec![root],
            edges: Vec::new(),
            accessible: Vec::new(),
            ordinal: 0,
        }
    }

    fn contains(&self, node_id: Uuid) -> bool {
        self.nodes
            .iter()
            .any(|node| uuid_field(node, "nodeId") == Some(node_id))
    }
}

fn append_sources(
    state: &mut GraphState,
    root: &Value,
    row: &Value,
    run_id: Uuid,
) -> Result<(), ServiceError> {
    for source in array_field(row, "sourceUses") {
        let Some(source_id) = uuid_field(source, "id") else {
            continue;
        };
        let source_node = node(NodeInput {
            node_id: source_id,
            node_type: "SOURCE_USE",
            label: format!(
                "출처 사용 · {}",
                string_field(source, "kind").unwrap_or_else(|| "UNKNOWN".to_owned())
            ),
            state: string_field(source, "kind").unwrap_or_else(|| "UNKNOWN".to_owned()),
            object_id: source_id,
            object_version: None,
            object_sha256: sha_field(source, "sourceUseSha256", &source_id.to_string()),
            locator: string_field(source, "locatorValue"),
            occurred_at: string_field(source, "occurredAt"),
            href: None,
        });
        let ordinal = state.ordinal;
        state.nodes.push(source_node.clone());
        state
            .edges
            .push(edge(source_id, run_id, "INPUT_TO", ordinal, run_id)?);
        state.accessible.push(accessible_row(
            &source_node,
            "입력으로 사용",
            root,
            ordinal,
        )?);
        state.ordinal += 1;
    }
    Ok(())
}

fn append_turns(
    state: &mut GraphState,
    root: &Value,
    row: &Value,
    run_id: Uuid,
) -> Result<(), ServiceError> {
    for turn in array_field(row, "providerTurns") {
        let Some(turn_id) = uuid_field(turn, "id") else {
            continue;
        };
        let turn_node = node(NodeInput {
            node_id: turn_id,
            node_type: "PROVIDER_TURN",
            label: format!(
                "Provider turn · {}",
                string_field(turn, "provider").unwrap_or_else(|| "UNKNOWN".to_owned())
            ),
            state: string_field(turn, "status").unwrap_or_else(|| "UNKNOWN".to_owned()),
            object_id: turn_id,
            object_version: None,
            object_sha256: sha_field(turn, "providerTurnSha256", &turn_id.to_string()),
            locator: None,
            occurred_at: string_field(turn, "completedAt"),
            href: None,
        });
        let ordinal = state.ordinal;
        state.nodes.push(turn_node.clone());
        state
            .edges
            .push(edge(run_id, turn_id, "DISPATCHED_AS", ordinal, run_id)?);
        state
            .accessible
            .push(accessible_row(root, "전달됨", &turn_node, ordinal)?);
        state.ordinal += 1;
    }
    Ok(())
}

fn append_citations(
    state: &mut GraphState,
    root: &Value,
    row: &Value,
    run_id: Uuid,
) -> Result<(), ServiceError> {
    for citation in array_field(row, "citations") {
        let Some(citation_id) = uuid_field(citation, "id") else {
            continue;
        };
        let citation_node = node(NodeInput {
            node_id: citation_id,
            node_type: "CITATION",
            label: "인용".to_owned(),
            state: "RECORDED".to_owned(),
            object_id: citation_id,
            object_version: None,
            object_sha256: sha_field(citation, "citationDigest", &citation_id.to_string()),
            locator: string_field(citation, "locatorValue"),
            occurred_at: None,
            href: None,
        });
        let source_id = uuid_field(citation, "sourceUseId")
            .filter(|source_id| state.contains(*source_id))
            .unwrap_or(run_id);
        let ordinal = state.ordinal;
        state.nodes.push(citation_node.clone());
        state
            .edges
            .push(edge(source_id, citation_id, "CITED_BY", ordinal, run_id)?);
        state.accessible.push(accessible_row(
            root,
            "인용으로 연결",
            &citation_node,
            ordinal,
        )?);
        state.ordinal += 1;
    }
    Ok(())
}

fn append_validations(
    state: &mut GraphState,
    root: &Value,
    row: &Value,
    run_id: Uuid,
) -> Result<(), ServiceError> {
    for validation in array_field(row, "validation") {
        let Some(validation_id) = uuid_field(validation, "id") else {
            continue;
        };
        let validation_node = node(NodeInput {
            node_id: validation_id,
            node_type: "OUTPUT_VALIDATION",
            label: "출력 검증".to_owned(),
            state: string_field(validation, "status").unwrap_or_else(|| "UNKNOWN".to_owned()),
            object_id: validation_id,
            object_version: None,
            object_sha256: sha_field(
                validation,
                "validatedOutcomeSha256",
                &validation_id.to_string(),
            ),
            locator: None,
            occurred_at: string_field(validation, "validatedAt"),
            href: None,
        });
        let turn_id = uuid_field(validation, "providerTurnId")
            .filter(|turn_id| state.contains(*turn_id))
            .unwrap_or(run_id);
        let ordinal = state.ordinal;
        state.nodes.push(validation_node.clone());
        state.edges.push(edge(
            turn_id,
            validation_id,
            "VALIDATED_BY",
            ordinal,
            run_id,
        )?);
        state
            .accessible
            .push(accessible_row(root, "검증됨", &validation_node, ordinal)?);
        state.ordinal += 1;
    }
    Ok(())
}

fn append_target(
    state: &mut GraphState,
    root: &Value,
    row: &Value,
    run_id: Uuid,
    case_id: Uuid,
    status: String,
) -> Result<(), ServiceError> {
    let target_id = stable_uuid("analysis-output", &run_id.to_string());
    let output_sha256 = canonical_json_digest(row.get("output").unwrap_or(&Value::Null))?;
    let target = node(NodeInput {
        node_id: target_id,
        node_type: "MATERIALIZED_TARGET",
        label: "분석 결과".to_owned(),
        state: status,
        object_id: target_id,
        object_version: Some(1),
        object_sha256: output_sha256,
        locator: None,
        occurred_at: string_field(row, "completedAt"),
        href: Some(href(case_id, run_id)),
    });
    let ordinal = state.ordinal;
    state.nodes.push(target.clone());
    state
        .edges
        .push(edge(run_id, target_id, "MATERIALIZED_AS", ordinal, run_id)?);
    state
        .accessible
        .push(accessible_row(root, "결과로 생성", &target, ordinal)?);
    Ok(())
}

pub fn provenance_graph(run_id: Uuid, case_id: Uuid, row: &Value) -> Result<Value, ServiceError> {
    let status = string_field(row, "status").unwrap_or_else(|| "UNKNOWN".to_owned());
    let root = node(NodeInput {
        node_id: run_id,
        node_type: "AGENT_RUN",
        label: "Agent 실행".to_owned(),
        state: status.clone(),
        object_id: run_id,
        object_version: row.get("version").and_then(Value::as_i64),
        object_sha256: sha_field(row, "inputSnapshotHash", &run_id.to_string()),
        locator: None,
        occurred_at: string_field(row, "createdAt"),
        href: Some(href(case_id, run_id)),
    });
    let mut state = GraphState::new(root.clone());
    append_sources(&mut state, &root, row, run_id)?;
    append_turns(&mut state, &root, row, run_id)?;
    append_citations(&mut state, &root, row, run_id)?;
    append_validations(&mut state, &root, row, run_id)?;
    append_target(&mut state, &root, row, run_id, case_id, status)?;
    finalize_graph(run_id, state)
}

fn finalize_graph(run_id: Uuid, state: GraphState) -> Result<Value, ServiceError> {
    let mut graph = json!({"schemaVersion":"provenance-graph.v2","agentRunId":run_id,"rootNodeId":run_id,"nodes":state.nodes,"edges":state.edges,"accessibleRows":state.accessible,"graphSha256":ZERO_SHA256,"accessibleRowsSha256":ZERO_SHA256});
    graph["accessibleRowsSha256"] = json!(canonical_json_digest(
        graph
            .get("accessibleRows")
            .ok_or(ServiceError::Persistence)?
    )?);
    let mut digest_input = graph.clone();
    digest_input
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .remove("graphSha256");
    graph["graphSha256"] = json!(canonical_json_digest(&digest_input)?);
    Ok(graph)
}
