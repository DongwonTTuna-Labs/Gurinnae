@hard-gate @final @supplemental @journey @postgresql
Feature: 업무 여정 인계는 명시적 그래프와 불변 영수증을 따라 원자적으로 생성·결정·대조된다

  Background:
    Given PostgreSQL 18.4에 실제 migration 전체와 20행 handoff registry가 적용돼 있다
    And Rust 1.97.0 domain/application과 production Docker topology가 실행 중이다
    And fixture는 입력에만 사용되고 assertion 대상 상태·영수증·ACL은 실제 PostgreSQL 경계를 통과한다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-001
  Scenario: 20행 handoff registry와 J-01부터 J-12 edge 참조가 정확히 같다
    When canonical journey와 handoff registry를 양방향 비교한다
    Then regex만으로 허용된 handoff는 0건이고 모든 edge 참조가 정확히 하나의 registry row로 해석된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-002
  Scenario: journey 시작은 version 1과 INSTANCE_STARTED receipt 하나를 원자적으로 만든다
    When 등록된 root object로 journey를 시작한다
    Then instance version과 receipt sequence는 1이고 audit outbox parent head가 모두 같은 digest를 가리킨다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-003
  Scenario: 일반 request는 generation 1 PENDING_ACK와 NOT_DUE를 만든다
    When ACTIVE instance에서 등록된 handoff edge를 요청한다
    Then HANDOFF_REQUESTED receipt 하나와 정확히 하나의 pending generation이 저장된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-004
  Scenario: 첫 database threshold는 NOT_DUE를 DUE로 한 번만 전환한다
    When PostgreSQL clock이 첫 escalation threshold에 도달한다
    Then 두 owner와 immutable binding은 유지되고 HANDOFF_ESCALATED가 한 번만 기록된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-005
  Scenario: 둘째 database threshold는 DUE를 ESCALATED로 한 번만 전환한다
    When PostgreSQL clock이 둘째 escalation threshold에 도달한다
    Then owner와 hard expiry는 유지되고 같은 generation은 다시 escalation되지 않는다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-006
  Scenario: acknowledgement는 persisted receiver에게 owner를 넘기고 escalation을 해결한다
    When exact receiver가 현재 binding을 ACKNOWLEDGE한다
    Then handoff는 ACKNOWLEDGED이고 current owner는 receiver이며 같은 generation은 RESOLVED다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-007
  Scenario: replacement 없는 decline은 encrypted reason을 저장하고 owner를 유지한다
    When exact receiver가 closed reason으로 DECLINE한다
    Then plaintext는 SQL에 전달되지 않고 parent는 ACTIVE 또는 BLOCKED이며 receipt와 reason digest가 검증된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-008
  Scenario: decline replacement는 DECLINED 다음 REQUESTED를 연속 version에 기록한다
    When compiled decline replacement 정책이 적용된다
    Then 두 step은 한 transaction이고 final parent에는 새 pending generation 하나만 있다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-009
  Scenario: replacement 없는 expiry는 database due time에만 EXPIRED receipt를 만든다
    When PostgreSQL clock이 immutable hard expiry에 도달한다
    Then owner는 유지되고 replacement receipt 없이 terminal old generation만 기록된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-010
  Scenario: expiry replacement는 EXPIRED 다음 REQUESTED를 연속 version에 기록한다
    When compiled expiry replacement 정책이 적용된다
    Then 두 step은 한 transaction이고 final parent는 generation plus one WAITING_ACK다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-011
  Scenario: pending handoff가 있는 terminal outcome은 CANCELLED 다음 OUTCOME_RECORDED다
    When compiled terminal cancellation policy로 definitive outcome을 기록한다
    Then 두 receipt가 연속되고 final parent에는 pending handoff가 없다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-012
  Scenario: compiled supersession만 SUPERSEDED 다음 REQUESTED를 만들 수 있다
    When pending generation에 supersession 또는 임의 재요청을 시도한다
    Then compiled supersession만 성공하고 임의 요청은 zero-write HANDOFF_STATE_INVALID다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-013
  Scenario: 등록된 definitive durable effect만 OUTCOME_RECORDED를 만든다
    When exact subject candidate와 effect receipt로 outcome을 기록한다
    Then compiled outcome state와 effect digest가 immutable receipt에 결속된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-014
  Scenario: 비권위 성공 신호는 journey outcome을 만들지 않는다
    When HTTP success queue acceptance provider acceptance AI output synthetic fixture 또는 unverified projection을 제출한다
    Then outcome receipt와 parent update는 모두 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-015
  Scenario: deferred chain trigger는 sequence minus one이 아닌 prior를 거부한다
    When receipt가 잘못된 prior sequence를 참조한다
    Then commit은 named parity constraint와 SQLSTATE 23514로 실패한다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-016
  Scenario: deferred chain trigger는 잘못된 prior identity와 continuity를 거부한다
    When prior ID digest instance state owner 또는 due continuity가 다르다
    Then transaction은 rollback되고 immutable chain은 변하지 않는다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-017
  Scenario: deferred instance head trigger는 모든 parent head drift를 거부한다
    When head ID sequence version digest state owner active handoff 또는 escalation이 receipt와 다르다
    Then commit은 실패하고 parent와 receipt graph는 원상태다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-018
  Scenario: deferred handoff head trigger는 request와 last head drift를 거부한다
    When request head 또는 last receipt version digest state가 다르다
    Then commit은 named handoff head parity 오류로 실패한다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-019
  Scenario: receipt parent FK는 immutable identity만 참조한다
    When pg_catalog의 모든 journey FK target을 검사한다
    Then receipt에서 mutable parent version candidate로 향하는 FK는 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-020
  Scenario: 64개 동시 일반 request는 pending generation 하나만 만든다
    When 같은 expected version으로 64 client가 동시에 request한다
    Then 승자는 하나이고 나머지는 zero-write이며 receipt event graph도 하나다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-021
  Scenario: due 전 lock을 획득한 human decision은 expiry보다 먼저 확정된다
    When decision이 database time을 due 전 캡처한 채 canonical lock을 보유한다
    Then decision만 commit되고 concurrent expiry는 zero-write다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-022
  Scenario: due 이후에는 human decision이 쓰지 못하고 expiry 하나만 이긴다
    When database time이 due 이상인 상태에서 decision과 expiry가 경쟁한다
    Then decision은 zero-write이고 expiry 승자는 정확히 하나다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-023
  Scenario: 잘못된 receiver capability scope assurance는 모두 zero-write다
    When receiver authorization의 한 차원을 변조한다
    Then instance handoff receipt audit outbox domain effect가 추가되지 않는다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-024
  Scenario: 잘못된 binding digest와 미등록 handoff row는 모두 거부된다
    When expected binding 또는 registry membership이 다르다
    Then typed error와 완전한 zero-write snapshot equality가 확인된다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-025
  Scenario: stale instance와 handoff version은 typed conflict만 반환한다
    When stale version으로 command 또는 scheduler routine을 호출한다
    Then VERSION_CONFLICT disposition이고 모든 transition field는 null이며 write는 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-026
  Scenario: 모든 runtime role은 세 relation의 직접 mutation을 거부당한다
    When 각 runtime role로 INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER를 시도한다
    Then 모든 조합이 privilege denial이고 owner routine만 상태를 바꿀 수 있다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-027
  Scenario: PUBLIC과 undeclared role은 모든 journey regprocedure를 실행할 수 없다
    When exact six signature와 모든 overload 후보의 EXECUTE privilege를 검사한다
    Then 선언된 role 이외의 effective EXECUTE는 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-028
  Scenario: pg_catalog ACL은 table function type registry와 양방향으로 같다
    When pg_class pg_proc pg_type aclexplode와 privilege 함수를 비교한다
    Then 누락 추가 ownership default grant가 모두 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-029
  Scenario: fresh assertion retry의 external command replay는 byte-identical business response다
    When 같은 stable business fields와 Idempotency-Key를 다른 transport request ID와 fresh actor assertion JTI로 다시 보낸다
    Then 새 replay-guard와 authorization-attempt audit은 각각 한 건이고 finalized response bytes는 원본과 byte-identical이다
    And domain idempotency receipt command-audit outbox relation의 row digest는 모두 같다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-030
  Scenario: 같은 idempotency key의 changed business bytes만 conflict다
    When fresh assertion JTI로 operation subject expected version or binding decision reasonCode reasonDigest 중 한 필드를 바꾼다
    Then IDEMPOTENCY_CONFLICT이고 authorization-attempt evidence 이외에는 ciphertext를 포함한 어떤 business state도 바뀌지 않는다
    And request ID assertion JTI token bytes randomized ciphertext 또는 plaintext-only 변화는 business conflict identity가 아니다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-031
  Scenario: escalation APPLIED_REPLAY는 immutable receipt를 반환하고 중복 효과가 없다
    When 같은 handoff version과 kind로 scheduler replay를 실행한다
    Then notification audit outbox transition은 추가되지 않는다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-032
  Scenario: expiry APPLIED_REPLAY는 replacement를 중복하지 않는다
    When 같은 expiry transition을 scheduler가 다시 관찰한다
    Then old expiry와 optional replacement receipt가 그대로 반환되고 새 row는 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-033
  Scenario: 모든 receipt UPDATE와 DELETE는 restore 이후에도 거부된다
    When receipt history를 직접 변경하거나 복원본에서 다시 쓴다
    Then immutable guard가 거부하고 chain digest는 같다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-034
  Scenario: immutable handoff routing subject authority due binding은 변경할 수 없다
    When terminal 전후에 immutable column 하나를 UPDATE한다
    Then SQLSTATE 55000이고 handoff bytes는 그대로다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-035
  Scenario: owner digest는 ACK 또는 명시된 non-handoff outcome에서만 바뀐다
    When decline escalation expiry cancel supersede와 ACK를 각각 실행한다
    Then ACK와 compiled owner-changing outcome 이외에는 current owner digest가 같다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-036
  Scenario: backup restore는 pending work claim 전에 모든 head를 복구한다
    When journey instance handoff receipt audit outbox를 backup에서 복원한다
    Then 모든 head digest가 일치한 뒤에만 pending work가 claimable하다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-037
  Scenario: 아홉 receipt kind는 정확한 여섯 routine partition으로만 도달한다
    When routine과 receipt kind 실행 조합 전체를 검사한다
    Then 선언된 조합만 성공하고 열 번째 kind 또는 우회 insert는 없다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-038
  Scenario: 여섯 event는 producer consumer envelope replay 계약이 정확하다
    When event payload와 consumer binding을 양방향 비교하고 replay한다
    Then eventId는 envelope에만 있고 세 consumer가 순서·gap·dedupe를 동일하게 처리한다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-039
  Scenario: PostgreSQL 18.4 catalog는 journey authority와 정확히 같다
    When relation column constraint index trigger function type owner search path ACL을 전수 비교한다
    Then 누락과 추가가 0건이고 모든 46 scenario의 실제 runtime 증거가 같은 source digest를 가리킨다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-040
  Scenario: 같은 assertion JTI 재사용은 business prepare 전에 거부된다
    When 첫 성공 또는 실패 시도와 동일한 valid actor assertion JTI를 다시 제출한다
    Then ACTOR_ASSERTION_REPLAYED이고 두 번째 replay-guard와 consumed-attempt audit과 protected business write는 모두 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-041
  Scenario: invalid assertion은 trusted attempt evidence도 만들지 않는다
    When signature audience expiry operation capability assurance 또는 exact wire binding을 하나씩 변조한다
    Then replay-guard authorization-attempt audit business idempotency domain receipt outbox는 모두 0건이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-042
  Scenario: assertion attempt commit 뒤 business begin 전 crash는 fresh JTI로 회복된다
    When replay-guard와 attempt audit commit 직후 business transaction 시작 전에 process를 중단한다
    Then 첫 시도의 protected business row는 0건이고 fresh JTI와 같은 key/hash 재시도는 NEW 한 번만 수행한다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-043
  Scenario: prepare NEW 뒤 commit 전 모든 crash는 claim effect finalization을 함께 rollback한다
    When prepare 뒤 encryption 전 encryption 뒤 apply 전 apply 뒤 finalize 전 finalize 뒤 commit 전 failpoint를 각각 실행한다
    Then 각 중단은 idempotency claim ciphertext domain command-audit outbox receipt response tuple을 전부 rollback하고 fresh JTI 재시도 효과는 한 번뿐이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-044
  Scenario: 64개 fresh JTI concurrent retry는 business winner 하나와 동일 response만 만든다
    When 같은 stable business hash와 Idempotency-Key를 64개 fresh JTI와 request ID로 동시에 보낸다
    Then replay-guard와 consumed-attempt audit은 각각 64건이고 NEW와 encryption과 domain effect는 각각 한 번이며 64개 application response tuple이 byte-identical이다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-045
  Scenario: finalized journey decision은 expires_at 이후에도 재claim되지 않는다
    When finalized idempotency row의 expires_at 이후 fresh JTI로 같은 key/hash와 changed hash를 각각 제출한다
    Then 같은 hash는 원본 bytes를 replay하고 changed hash는 conflict이며 generation response bytes domain effect는 변하지 않는다

  # scenario-id: AC-JOURNEY_HANDOFF_ADDENDUM-046
  Scenario: persisted service acknowledgement authority도 fresh service JTI 계약을 따른다
    When workflow worker가 persisted service ACK binding으로 exact replay duplicate JTI changed business hash를 각각 보낸다
    Then SERVICE_ASSERTION_REPLAYED와 FINAL_REPLAY와 IDEMPOTENCY_CONFLICT가 actor 경로와 같은 write cardinality로 분리된다
