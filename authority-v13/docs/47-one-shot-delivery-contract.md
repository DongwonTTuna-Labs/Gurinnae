# 47. 원샷 납품 계약

구현은 내부적으로 순서를 가질 수 있지만, 발주자에게는 완제품만 납품한다.

## 허용되는 내부 작업

- dependency graph 작성
- 작은 commit
- test-first
- parallel worker
- temporary local branch

## 허용되지 않는 최종 상태

- 일부 화면만 완성
- fixture만 가능
- live connector 없음
- auth 없음
- 운영 기능 없음
- 디자인 placeholder
- API 계약 누락
- "다음 단계에서"

## 키 삽입 후 기동

운영자가 `specs/config/secret-and-key-catalog.yaml`에 명시된 값을 넣으면:

1. preflight가 형식과 연결을 검증한다.
2. migrator가 schema를 적용한다.
3. source connector가 활성화된다.
4. worker가 checkpoint부터 수집한다.
5. public/control/submission API가 readiness를 통과한다.
6. 세 SSR 앱이 내부 API 주소로 연결된다.
7. synthetic banner 없이 production mode로 서비스된다.
