# Runtime LOGIN Role Bootstrap

권한 role은 NOLOGIN이며 secret manager가 관리하는 별도 LOGIN role에 GRANT한다. 모든 LOGIN role은 NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOBYPASSRLS, NOINHERIT를 사용한다. 최종 테스트는 pg_catalog와 실제 negative query로 권한을 검증한다.


## Identity API runtime role

`gurine_identity_api_login`은 `gurine_identity_api` privilege role 하나만 `SET ROLE`할 수 있다. OIDC transaction, opaque session, step-up authorization 외 schema에는 접근할 수 없으며 `rolsuper=false`, `rolbypassrls=false`, `rolinherit=false`를 runtime test로 검증한다.
