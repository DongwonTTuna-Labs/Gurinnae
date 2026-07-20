# Generated Operational Artifacts

최종 구현에서 다음 파일은 Rust와 OpenAPI generator가 결정적으로 생성한다.

```text
public-api.openapi.json
control-api.openapi.json
submission-api.openapi.json
packages/api-client-public/src/generated/**
packages/api-client-control/src/generated/**
packages/api-client-submission/src/generated/**
.sqlx/**
```

직접 수정하지 않는다. `make verify-final`은 깨끗한 임시 디렉터리에 다시 생성한 뒤
체크인된 결과와 비교한다. 차이가 있으면 실패한다.
