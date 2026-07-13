# 54. No Placeholder Policy

최종 source에는 다음이 없어야 한다.

- TODO / TBD / FIXME for required behavior
- placeholder screen
- empty handler
- `unimplemented!()`
- 501 response
- mock-only repository selected in production
- hard-coded fixture in production path
- disabled acceptance test
- missing operation
- generic `serde_json::Value`로 domain contract 대체
- generic catch-all UI without screen-specific hierarchy

validator와 CI가 이를 검색한다.
