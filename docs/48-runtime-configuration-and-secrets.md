# 48. Runtime Configuration and Secrets

모든 환경변수는 `specs/config/runtime-config.schema.json`과
`specs/config/secret-and-key-catalog.yaml`에 정의한다.

원칙:

- secret는 environment/secret manager에서만 주입
- 서비스별 최소 권한
- production에서 default secret 금지
- raw token/password logging 금지
- key rotation 지원
- missing source key는 해당 source만 disabled
- missing foundational security key는 startup fail
- public health에는 secret 존재 여부나 provider detail을 노출하지 않음
