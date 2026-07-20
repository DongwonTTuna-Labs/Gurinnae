# Final Configuration Contract

`secret-and-key-catalog.yaml`이 모든 environment variable의 권위다.

## Development

`.env.example`의 local-only 값과 synthetic source를 사용한다. 실제 외부 key가 없어도 전체 화면과 workflow가 작동한다.

## Production

`.env.production.example`을 secret manager 값으로 채운 뒤 `make production-preflight`를 실행한다.
preflight는 다음을 검사한다.

- placeholder/default secret 없음
- base URL HTTPS
- PostgreSQL 연결과 role
- OIDC discovery/client
- SMTP handshake
- object store bucket/read/write/delete probe
- source key와 quota probe
- OTLP 연결
- AI provider key/model probe when enabled
- ClamAV when uploads enabled

검사 결과는 secret 값을 포함하지 않는 JSON receipt로 남긴다.
