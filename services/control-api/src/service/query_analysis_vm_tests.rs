use super::*;

#[test]
fn graph_and_visualization_digests_are_bound() {
    let run = Uuid::new_v4();
    let case_id = Uuid::new_v4();
    let mut row = json!({"id":run,"caseId":case_id,"status":"SUCCEEDED","agentType":"investigator","objective":"검증","inputSnapshotHash":ZERO_SHA256,"version":1,"createdAt":"2026-07-19T00:00:00Z","updatedAt":"2026-07-19T00:00:00Z","sourceUses":[],"providerTurns":[],"validation":[],"citations":[],"suggestions":[],"output":null,"maxCost":"0","actualCost":"0"});
    assert!(attach_cas011(&mut row).is_ok());
    let vm_option = row.get("analysisVm");
    assert!(vm_option.is_some());
    let Some(vm) = vm_option else { return };
    let graph_option = vm.get("provenanceGraph");
    assert!(graph_option.is_some());
    let Some(graph) = graph_option else { return };
    let mut graph_input = graph.clone();
    let graph_object_option = graph_input.as_object_mut();
    assert!(graph_object_option.is_some());
    let Some(graph_object) = graph_object_option else {
        return;
    };
    graph_object.remove("graphSha256");
    let graph_digest_result = canonical_json_digest(&graph_input);
    assert!(graph_digest_result.is_ok());
    let Ok(graph_digest) = graph_digest_result else {
        return;
    };
    assert_eq!(graph.get("graphSha256"), Some(&json!(graph_digest)));
    let visual_option = vm.get("visualizations");
    assert!(visual_option.is_some());
    let Some(visual) = visual_option else { return };
    let entries_option = visual.get("visualizations").and_then(Value::as_array);
    assert!(entries_option.is_some());
    let Some(entries) = entries_option else {
        return;
    };
    for entry in entries {
        assert_eq!(
            entry.get("dataSha256"),
            entry
                .get("tableAlternative")
                .and_then(|table| table.get("dataSha256")),
            "metric and accessible table must share one canonical digest",
        );
    }
    let digest_input = entries.iter().map(|item| json!({"visualizationId":item["visualizationId"],"dataSha256":item["dataSha256"]})).collect::<Vec<_>>();
    let set_digest_result = canonical_json_digest(&json!(digest_input));
    assert!(set_digest_result.is_ok());
    let Ok(set_digest) = set_digest_result else {
        return;
    };
    assert_eq!(
        visual.get("visualizationSetSha256"),
        Some(&json!(set_digest))
    );
}

#[test]
fn materialized_target_digest_is_bound_to_canonical_output() {
    let run = Uuid::new_v4();
    let case_id = Uuid::new_v4();
    let mut first = json!({
        "id": run,
        "caseId": case_id,
        "status": "SUCCEEDED",
        "inputSnapshotHash": ZERO_SHA256,
        "version": 1,
        "createdAt": "2026-07-19T00:00:00Z",
        "sourceUses": [],
        "providerTurns": [],
        "validation": [],
        "citations": [],
        "output": {
            "answerFirstSummary": "검증 결과",
            "hypotheses": [{"statement": "가설 A"}],
            "unknowns": ["계약 원문 확인 필요"]
        }
    });
    let mut second = first.clone();
    second["output"]["answerFirstSummary"] = json!("변경된 검증 결과");

    assert!(attach_cas011(&mut first).is_ok());
    assert!(attach_cas011(&mut second).is_ok());

    let target_digest = |row: &Value| {
        row.pointer("/analysisVm/provenanceGraph/nodes")
            .and_then(Value::as_array)
            .and_then(|nodes| {
                nodes.iter().find(|node| {
                    node.get("nodeType").and_then(Value::as_str) == Some("MATERIALIZED_TARGET")
                })
            })
            .and_then(|node| node.get("objectSha256"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    };
    let expected = canonical_json_digest(first.get("output").unwrap_or(&Value::Null));

    assert!(expected.is_ok());
    assert_eq!(target_digest(&first), expected.ok());
    assert_ne!(target_digest(&first), target_digest(&second));
    assert_ne!(
        first.pointer("/analysisVm/provenanceGraph/graphSha256"),
        second.pointer("/analysisVm/provenanceGraph/graphSha256")
    );
}
