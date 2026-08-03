# 40. 최종 제품 분석·품질 측정

## 목적

Analytics는 참여 중독이나 선정성 최적화가 아니라 다음을 측정한다.

- 사용자가 상태와 한계를 이해하는가
- 공개 근거에 접근하고 계산을 재현하는가
- 소명·정정 절차를 완료할 수 있는가
- 내부 작업에서 누락·오판·stale approval이 줄어드는가
- source와 운영 장애를 빠르게 발견하는가

## 허용 이벤트

정확한 event/property allowlist는 `specs/ui/analytics-events.yaml`이 권위다.
화면별 event는 `screen-catalog.yaml`과 양방향으로 연결된다.

## 금지 데이터

- 검색어에 포함된 개인정보
- 정정·문의·소명 본문
- response/management/receipt token
- 첨부파일 이름
- evidence 원문
- 내부 audit details
- 이메일·IP·user-agent 원문

## 핵심 품질 지표

### 이해도
- anomaly와 wrongdoing 구분 성공률
- confirmed/unknown/response 식별 성공률
- correction/retraction 인지율

### 절차
- response 제출 완료율과 오류 단계
- correction receipt 도달률
- review blocker 해결 시간
- stale snapshot 차단 건수

### 신뢰성
- source freshness SLA
- schema drift detection latency
- public/private leakage 0
- audit chain verification
- restore rehearsal 성공

## 인간 검증

최종 acceptance에는 다음 task-based 검증을 포함한다.

- 시민: 사건의 현재 상태와 미확인을 30초 안에 설명
- 기자: 계산과 원본을 재현·인용
- 조사자: 다음 blocker와 담당 작업 식별
- 검토자: snapshot 차이와 독립성 확인
- 기관/업체 담당자: 공개 동의 범위를 이해하고 제출
- 키보드·screen reader 사용자: 주요 여정 완료
