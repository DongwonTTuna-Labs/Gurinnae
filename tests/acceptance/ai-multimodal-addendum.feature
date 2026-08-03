@hard-gate @final @supplemental @agent @internet @multimodal
Feature: AI 조사는 고정 근거·권리·비용 안에서 인터넷과 HTML·이미지·WAV·WebM을 분석하고 사람이 즉시 검증할 수 있게 보여준다

  Background:
    Given PostgreSQL 18.4에 READY AGENT_CASE snapshot과 revision-fixed EvidenceSegment가 있다
    And analysis-worker, document-extractor, egress-gateway, control-api와 Review Console이 production 구성으로 실행 중이다
    And fixture는 입력과 외부 provider double 경계에만 사용되고 assertion 대상 효과는 production domain과 repository를 통과한다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-001
  Scenario: 모든 v2 JSON Schema가 닫혀 있고 참조가 실제 파일로 해석된다
    When addendum-v2의 모든 JSON 문서를 Draft 2020-12 metaschema로 검사한다
    Then JSON syntax error는 0건이다
    And 모든 object의 required key는 같은 object의 properties에 존재한다
    And 모든 local $ref와 $id는 유일하게 해석된다
    And additionalProperties가 열린 request, response, persistence type, view-model은 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-002
  Scenario: 9개 tool은 서로 다른 request와 response 계약을 실제 dispatch에서 강제한다
    When 9개 tool의 valid request와 valid response를 각 실제 adapter에 전달한다
    Then 9개 call은 자신의 schema와 snapshot scope로만 성공한다
    When 각 tool에 다른 8개 tool의 request 또는 response를 교차 전달한다
    Then 72개 request 교차 조합과 72개 response 교차 조합이 dispatch 전에 거부된다
    And provider turn, tool claim, budget charge, source use, proposal은 추가되지 않는다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-003
  Scenario: 8개 internal tool은 snapshot-scoped PostgreSQL adapter를 사용한다
    When claim.language_check, contract.find_comparables, entity.lookup, evidence.read, evidence.search, response.read, rule.reproduce, source.locator_verify를 한 번씩 실행한다
    Then 각 결과는 실제 typed repository query와 immutable snapshot member를 통과한다
    And inaccessible, stale, 다른 snapshot 또는 존재하지 않는 ID는 결과·count·snippet·timing으로 누출되지 않는다
    And generic 검색 결과나 합성 UUID·digest·timestamp는 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-004
  Scenario: source.fetch만 승인된 egress-gateway로 정적 공개 웹을 수집한다
    Given current source-access rights와 PUBLIC_RESEARCH capability activation이 있다
    When source.fetch가 SEARCH_PUBLIC_WEB 뒤 FETCH_URL을 실행한다
    Then analysis-worker의 직접 DNS와 socket 호출은 0회다
    And gateway는 HTTPS, 매 redirect DNS/IP, private range, byte, time, media, rights와 rate policy를 검사한다
    And raw bytes와 safe headers는 hash-pinned ResearchArtifact로 저장된다
    And JavaScript가 필요한 페이지는 RENDER_REQUIRED이며 조용히 불완전 성공하지 않는다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-005
  Scenario Outline: 5개 agent는 bounded multi-turn loop와 exact output schema를 사용한다
    Given agent type이 <agent>이고 그 agent의 exact prompt와 output schema digest가 고정돼 있다
    When provider가 TOOL_CALL 하나와 그 다음 FINAL_OUTPUT을 반환한다
    Then turn sequence, prior transcript, tool call, source uses, provider receipts, validation과 cost가 하나의 연속 digest chain이다
    And <agent>에게 허용되지 않은 tool은 dispatch 전에 DENIED이다
    And FINAL_OUTPUT은 <agent> 전용 schema를 통과하기 전에는 proposal을 만들지 않는다

    Examples:
      | agent             |
      | market-researcher |
      | investigator      |
      | skeptic           |
      | claim-drafter     |
      | citation-verifier |

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-006
  Scenario: 다음 turn의 worst-case 비용이 남은 한도를 넘으면 외부 호출 전에 중단한다
    Given run의 남은 budget이 다음 provider reservation보다 1 micro-KRW 작다
    When dispatcher가 다음 turn을 시도한다
    Then run은 BUDGET_BLOCKED/SETTLED이다
    And 추가 provider request와 tool call은 0회다
    And 예약·정산·해제 합계와 terminal receipt가 정확히 일치한다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-007
  Scenario: dispatch 전 취소는 즉시 끝나고 dispatch 후 취소는 증명 전까지 요청 상태다
    Given 하나의 QUEUED run과 provider claim이 가능한 하나의 RUNNING run이 있다
    When 사용자가 expected version과 reason으로 둘을 취소한다
    Then QUEUED run은 CANCELLED/SETTLED이며 provider 호출은 0회다
    And RUNNING run은 RUNNING/CANCEL_REQUESTED이고 취소 요청만으로 CANCELLED가 되지 않는다
    And 두 결과 모두 immutable control receipt와 idempotent replay를 가진다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-008
  Scenario: send 이후 timeout은 새 호출이 아니라 같은 idempotency proof로 reconcile한다
    Given provider가 요청을 받을 수 있었지만 local completion 전에 연결이 끊겼다
    When analysis-worker가 timeout을 기록하고 reconciliation-worker가 조회한다
    Then run은 먼저 RUNNING/RECONCILIATION_REQUIRED이다
    And 같은 semantic request, snapshot, transcript와 provider idempotency key만 사용한다
    And authenticated lookup 결과에 따라 정확히 SUCCEEDED, FAILED, CANCELLED 또는 safe retry로 이동한다
    And provider turn, result와 cost는 중복되지 않는다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-009
  Scenario Outline: output hard failure는 전체 output을 막고 proposal을 하나도 남기지 않는다
    Given FINAL_OUTPUT에 <failure>가 있다
    When JSON schema, snapshot, citation, source-use, rights, classification, policy 순서로 검증한다
    Then INVALID OutputValidation 한 건과 typed failure code가 저장된다
    And AgentProposal과 proposal citation insert는 0건이다
    And 부분적으로 유효한 항목도 materialize되지 않는다

    Examples:
      | failure                         |
      | output schema mismatch           |
      | stale snapshot                    |
      | source outside snapshot           |
      | locator mismatch                  |
      | selected content hash mismatch    |
      | missing source-use relation       |
      | expired or denied rights          |
      | classification denial             |
      | prompt injection propagation      |

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-010
  Scenario: citation은 exact source use와 immutable source revision을 관계형으로 잇는다
    When 유효한 EvidenceSegment citation을 검증한다
    Then citation에서 source-use, tool/provider turn, snapshot member, EvidenceSegment, SourceDocument asset revision과 rights decision까지 FK로 순회된다
    And locator 재추출 text의 SHA-256이 selectedContentSha256과 같다
    And JSON ID array나 provider 답변만으로 대체한 관계는 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-011
  Scenario: ResearchArtifact는 promotion 전까지 authoritative Evidence가 아니다
    Given source.fetch 결과가 CLEAN ResearchArtifact와 AI summary를 만들었다
    When claim, publication 또는 external action이 그 artifact를 직접 사용하려 한다
    Then command는 UNPROMOTED_RESEARCH_ARTIFACT로 거부된다
    And CAS-011은 research-only 상태와 promotion 가능 여부·이유를 표시한다
    And AI 자신은 promotion을 실행할 수 없다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-012
  Scenario: 사람의 promotion은 artifact에서 SourceDocument와 Evidence를 원자적으로 만든다
    Given CLEAN STORED artifact, current rights GRANT, in-bounds locator와 expected case version이 있다
    When 권한 있는 사용자가 promoteResearchArtifactToEvidence를 제출한다
    Then artifact/fetch/run/turn/call/bytes/rights가 exact candidate key로 검증된다
    And 실제 parser 결과로 SourceDocument, EvidenceSegment, Evidence, HUMAN_PROMOTION source use, audit, outbox와 receipt가 한 transaction에서 생성된다
    And 같은 Idempotency-Key와 같은 bytes replay는 byte-equivalent receipt와 zero new row를 반환한다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-013
  Scenario Outline: promotion precondition 실패는 partial authority를 남기지 않는다
    Given promotion 입력의 <condition>이 유효하지 않다
    When promoteResearchArtifactToEvidence를 제출한다
    Then exact typed error로 실패한다
    And 새 SourceDocument, segment, Evidence, source use, audit와 outbox는 모두 0건이다

    Examples:
      | condition                    |
      | case version                 |
      | artifact digest              |
      | run ownership                |
      | safety state                 |
      | rights decision              |
      | locator                      |
      | selected content hash        |
      | changed idempotency payload  |

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-014
  Scenario: CAS-010은 실행 목적·상태·핵심 결과·unknown·비용·다음 행동을 먼저 보여준다
    Given 성공, abstention, 실행 중, reconciliation, budget-blocked run이 함께 있다
    When wide, compact, 200%와 400% zoom에서 CAS-010을 연다
    Then 각 row가 human label, objective, status/control, snapshot freshness, 핵심 결과, 가장 중요한 unknown, proposal state와 실제 cost를 제공한다
    And 사용자는 raw JSON이나 opaque UUID를 해석하지 않고 10초 질문에 답한다
    And compact에서도 blocker와 primary action이 먼저이며 keyboard focus와 table label이 보존된다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-015
  Scenario: CAS-011은 검증된 분석과 provenance를 동일한 사실로 제공한다
    Given citations, counter-evidence, unknowns, tool timeline, proposals와 promotion 후보가 있는 run이다
    When CAS-011을 screen reader와 keyboard로 검토한다
    Then identity, inputs, model, output, citations, safety, decisions, cost 순서가 유지된다
    And AnalysisVm에는 summary, hypotheses, counter-evidence, 조사한 방법, unknowns와 next actions가 분리돼 있다
    And chart, narrative, accessible table과 ProvenanceGraph가 같은 data digest와 set-equal facts를 가진다
    And citation activation은 exact locator를 열고 돌아올 때 원래 control로 focus를 복원한다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-016
  Scenario: HTML PNG JPEG WebP TIFF WAV WebM embedded golden bytes를 실제 parser가 추출한다
    When parser addendum의 7개 base64 payload를 fresh directory에 materialize한다
    Then 각 byte length, SHA-256와 magic 또는 structure가 manifest와 같다
    When approved exact WAV/WebM runtime activation을 포함한 production document-extractor가 그 7개 파일을 처리한다
    Then HTML block/table/link, image OCR text·word·line bbox, WAV silence metadata와 WebM visual shot/no-audio state가 expected extraction oracle을 만족한다
    And 무음 WAV는 transcript와 speaker를 만들지 않고 무음 또는 audio-absent WebM은 audio transcript를 만들지 않는다
    And parser/version/traineddata/source/locator/extraction digest가 typed repository에서 byte-equivalent round-trip된다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-017
  Scenario: HTML active content는 실행되지 않고 source data로만 남는다
    Given embedded HTML에 script와 외부 HTTPS link가 있다
    When production HTML parser가 처리한다
    Then executed script와 fetched subresource는 각각 0건이다
    And ACTIVE_CONTENT_IGNORED warning, visible text, table와 link locator가 정확하다
    And page content는 tool instruction, system prompt 또는 capability로 승격되지 않는다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-018
  Scenario Outline: malformed 또는 resource-exhausting media는 typed rejection과 zero partial output을 만든다
    Given <mutation>인 additive media 입력이 있다
    When production parser sandbox가 처리한다
    Then exact rejection code와 input digest를 보존한다
    And segment, table, link와 authoritative evidence insert는 0건이다
    And network, unsafe FFI, unbounded allocation과 fixture-name branch는 사용되지 않는다

    Examples:
      | mutation                    |
      | one-byte corrupted checksum |
      | truncated image             |
      | oversized dimensions        |
      | pixel allocation overflow   |
      | animated WebP               |
      | multipage TIFF              |
      | HTML depth limit            |
      | HTML node limit             |
      | truncated WAV               |
      | WAV duration limit          |
      | truncated WebM              |
      | unsupported WebM video codec|

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-019
  Scenario Outline: provider receipt는 외부 결과와 비용의 유일한 정규화 증명이다
    Given provider outcome이 <outcome>이다
    When adapter가 response 또는 lookup evidence를 정규화한다
    Then semantic request, candidate/model/config, idempotency hash, proof, usage, cost, region, retention, rights와 time이 receipt digest에 결속된다
    And raw credential-like provider ID, prompt bytes, source text와 hidden reasoning은 저장되지 않는다
    And 불완전하거나 모순된 proof는 성공이 아니라 OUTCOME_UNKNOWN이다

    Examples:
      | outcome                    |
      | accepted final output      |
      | accepted tool call         |
      | definitive rejection       |
      | rate limit                 |
      | timeout before send        |
      | timeout after possible send|
      | malformed receipt          |
      | contradictory usage        |

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-020
  Scenario: fixture와 provider double은 production implementation을 대신하지 않는다
    When release source와 runtime branch를 검사한다
    Then fixture ID, filename, expected text, checksum 또는 provider-double result로 production parser/tool output을 선택하는 branch는 0건이다
    And 9개 tool adapter, parser, dispatcher, persistence, API와 view-model code path가 synthetic 및 non-fixture input에서도 같다
    And WAV/WebM 또는 mandatory ASR runtime activation이 닫히지 않으면 support claim과 release gate는 실패하고 silent fallback은 0건이다
    And skipped, ignored, pending, only, placeholder, 501과 zero-assertion hard gate는 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-021
  Scenario: non-silent 한국어와 영어 WAV는 실제 timestamped transcript가 된다
    Given 고정된 비식별 한국어 문장과 영어 문장 사이에 500 ms 무음이 있는 exact WAV fixture다
    When final document-extractor가 pinned whisper.cpp executable, model과 exact argv로 두 번 처리한다
    Then transcript state는 TRANSCRIBED이고 두 언어 문구가 검색 가능하다
    And 모든 half-open timestamp는 decoded duration 안이며 confidence는 5500 basis points 이상이다
    And input, generated WAV, executable, model, config, segment와 receipt digest는 두 실행에서 byte-identical이다
    And speaker label은 null이고 production fixture shortcut은 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-022
  Scenario: 두 음성의 발화는 보존하지만 diarization 없이는 화자를 만들지 않는다
    Given 두 synthetic voice가 겹치지 않게 한국어와 영어 발화를 교대하는 exact WAV fixture다
    When mandatory ASR가 transcript를 만들고 diarization adapter는 NOT_ACTIVATED다
    Then 두 발화 text와 time range는 보존된다
    And 모든 speaker label과 speaker confidence는 null이다
    And channel, 음색, 이름 또는 모델 추정으로 화자 identity를 합성한 row는 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-023
  Scenario: 세 장면 WebM은 deterministic shot OCR transcript와 optional VLM proposal을 만든다
    Given 서로 다른 도형과 한영 label, non-silent narration을 가진 세 장면 exact WebM fixture다
    When final FFmpeg, image OCR와 mandatory ASR path가 처리한다
    Then integer scene-change 알고리즘은 정확히 세 half-open shot과 shot별 대표 frame을 만든다
    And 각 keyframe OCR, narration transcript, region/time locator와 structural digest가 재실행과 같다
    When exact model-use rights와 VLM activation이 있거나 없다
    Then 활성 시에만 proposal-only MediaVisualProposalV1이 생기고 비활성 시 NOT_ACTIVATED 또는 POLICY_BLOCKED가 명시된다
    And 두 경우 모두 structural shot, OCR, transcript 또는 Evidence를 VLM이 대체하지 않는다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-024
  Scenario: non-speech low-confidence와 VLM rights denial은 fabricated 의미를 만들지 않는다
    Given deterministic tone/noise WAV와 model_use가 거부된 세 장면 WebM이 있다
    When production semantic media adapters가 처리한다
    Then WAV는 NON_SPEECH 또는 LOW_CONFIDENCE이고 transcript text와 segment는 0건이다
    And WebM의 VLM provider call과 VLM proposal은 0건이며 state는 POLICY_BLOCKED이다
    And structural shot, OCR, rights decision, abstention과 receipt만 정확히 보존된다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-025
  Scenario: multimodal locator는 ingest에서 search citation과 CAS focus return까지 동일하다
    Given transcript, keyframe OCR와 shot locator를 가진 immutable media revision이 있다
    When ingest, parser, segment persistence, authorized search, Agent source-use, citation validation과 CAS-011을 순서대로 실행한다
    Then 검색 hit와 citation은 같은 asset revision, content digest, exact time/region locator와 selected-content digest를 가리킨다
    And citation을 열었다 돌아오면 원래 control로 focus가 복원된다
    When locator, digest, rights 또는 snapshot membership 한 바이트를 바꾼다
    Then search disclosure, SourceUse, citation, proposal과 Evidence는 모두 0건이다

  # scenario-id: AC-AI_MULTIMODAL_ADDENDUM-026
  Scenario: ASR와 VLM provider receipt 비용과 ambiguity는 중복 없이 정산된다
    Given valid, malformed, contradictory와 timeout-after-possible-send provider evidence가 각각 있다
    When adapter가 exact request, model/config, rights, region, retention, usage, price와 FX를 검증한다
    Then valid evidence만 integer micro-KRW로 한 번 settle된다
    And malformed 또는 contradictory evidence는 성공하지 않고 timeout-after-send는 RECONCILIATION_REQUIRED다
    And possible send 뒤 fallback call은 0회이며 reservation, provider turn, result와 proposal은 중복되지 않는다
    And prompt, source text, raw provider ID, credential과 hidden reasoning은 log metric receipt에 없다
