# 공개 정정 요청·구독 흐름 Wireframe

## 정정 요청

```text
Step 1 대상 선택: 사건/revision/claim/evidence
Step 2 오류 유형: 사실/단위/신원/누락/개인정보/기타
Step 3 설명과 공개 source link
Step 4 연락·privacy·긴급 안전 요청
Step 5 검토 → 제출
Receipt: request ID, 제출 시각, 예상 절차, 추가 자료 링크
```

- 허위 신고 경고보다 구체적인 수정 근거와 안전한 연락 방식을 우선한다.
- 실제 위험 또는 개인정보 긴급 요청은 일반 정정 SLA와 분리한다.
- body, filename, token을 analytics에 보내지 않는다.
- 접수 화면은 수정이 반영됐다고 오인시키지 않는다.

## 구독

```text
대상: 사건/기관/업체/방법론/정정
빈도: 즉시/일일/주간
이메일 입력 → verification → 구독 확인
magic management link → 목록/빈도/해지
```

- 공개 읽기 계정을 만들지 않는다.
- 이메일 존재 여부를 응답 차이로 노출하지 않는다.
- 링크는 짧은 만료·회전·one-time 또는 안전한 session 교환을 사용한다.
- unsubscribe는 로그인 없이 가능하고 즉시 receipt를 제공한다.
- 구독량이나 인기 순위를 공개하지 않는다.
