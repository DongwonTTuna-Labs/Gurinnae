/// Funding is a public governance surface, not a marketing placeholder. The
/// public projection fails closed to UNKNOWN until a signed disclosure exists.
fn funding_content() -> Result<Value, ServiceError> {
    let updated_at = now()?;
    let source_links = vec![
        json!({"rel":"policy","href":"/about/governance","label":"거버넌스와 독립성"}),
        json!({"rel":"policy","href":"/about/funding","label":"재원 공개 기준"}),
        json!({"rel":"reports","href":"/transparency-reports","label":"투명성 보고서"}),
    ];
    let sections = vec![
        json!({"id":"principles","heading":"독립성 원칙","body":"편집팀은 후원자·고객의 조사 면제, 선공개, 비공개, 순위·임계값 변경 요청을 거부합니다. 결제는 편의·속도·분석 도구에만 연결되고 공개 사실과 근거는 무료로 남습니다.","links":source_links.clone(),"updatedAt":updated_at}),
        json!({"id":"income","heading":"재원","body":"현재 공개 projection에 서명된 재원 disclosure revision이 없어 후원·재단 지원·회원·API/SaaS 수입의 금액대와 목적은 UNKNOWN입니다. 값이 확정되면 출처·기간·금액대·목적·공개 근거를 함께 표시합니다.","links":[{"rel":"policy","href":"/about/governance","label":"허용 수익원과 금지 거래"}],"updatedAt":updated_at}),
        json!({"id":"expenses","heading":"비용","body":"인프라·데이터 라이선스·법률 검토·보안·정정 운영 비용은 서명된 공개 원장이 없으므로 UNKNOWN입니다. 비용을 0으로 추정하거나 조사 결과와 교환하지 않습니다.","links":[{"rel":"policy","href":"/about/governance","label":"공개 비용과 법률 방어 기금"}],"updatedAt":updated_at}),
        json!({"id":"donors","heading":"공개 기준","body":"단일 출처가 예상 연매출의 15%를 넘으면 oversight review, 25%를 넘으면 board 승인과 강화된 공개, 조사 대상 또는 관계자가 5%를 넘으면 independent review를 적용합니다. 현재 각 threshold 결과는 UNKNOWN입니다.","links":[{"rel":"policy","href":"/about/governance","label":"후원자·고객 투명성 기준"}],"updatedAt":updated_at}),
        json!({"id":"conflicts","heading":"이해상충","body":"고객·후원자 여부는 조사 우선순위 입력이 될 수 없습니다. 이해상충이 발견되면 회피·독립 검토·공개 범위를 기록합니다. 현재 case별 공개 결과는 서명된 revision이 없어 UNKNOWN입니다.","links":[{"rel":"policy","href":"/about/governance","label":"역할 분리와 이해상충"}],"updatedAt":updated_at}),
        json!({"id":"reports","heading":"보고서","body":"기간별 transparency report는 공개 endpoint에서 조회할 수 있습니다. 보고서가 없거나 stale이면 빈 성공 대신 UNKNOWN 상태와 재검토 경로를 표시합니다.","links":[{"rel":"reports","href":"/transparency-reports","label":"투명성 보고서 목록"}],"updatedAt":updated_at}),
    ];
    Ok(json!({
        "id":{"id":"funding","status":"PUBLISHED","version":1},"version":1,"status":"PUBLISHED",
        "updatedAt":updated_at,"title":"재원 공개","summary":"재원·비용·이해상충 공개 상태와 편집 독립성 guardrail을 확인합니다.",
        "data":{"version":"1.0","title":"재원 공개","updatedAt":updated_at,"sections":sections,"sourceLinks":source_links},
        "links":[{"rel":"self","href":"/v1/content/funding"},{"rel":"reports","href":"/transparency-reports"}],
    }))
}
