# 46. 화면 구성 표준

모든 화면은 `screen-build-manifest.yaml`과 해당 `specs/ui/screens/<ID>.md`를 구현한다.

## 고정 region

- global status
- application header
- breadcrumb or contextual path
- page header
- primary content
- supporting context
- completion/next action
- footer or audit metadata

## 화면 상단 900px 규칙

wide viewport 1440×900에서 사용자는 스크롤 전 다음을 확인할 수 있어야 한다.

- 화면 목적
- 객체 상태
- 가장 중요한 질문에 대한 답
- 주 action
- 데이터 freshness 또는 limitation
- 고위험 화면이면 blocker

## interaction 규칙

- destructive action은 confirmation dialog + reason
- save와 submit 분리
- URL로 복구 가능한 filter
- pagination baseline, infinite scroll 금지
- optimistic update는 서버 receipt로 확정
- conflict는 사용자 입력을 보존
- background refresh는 현재 읽기 위치를 흔들지 않음
