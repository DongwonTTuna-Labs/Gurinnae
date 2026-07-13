# 내부 인증·권한·감사 Wireframe

## 로그인·재인증

- 조직 IdP redirect 이전에 목적과 사용할 계정을 설명한다.
- MFA 실패, 세션 만료, clock skew, 권한 없음, IdP 장애를 구분한다.
- session expiry에서 작성 중 draft를 보존하고 인증 후 안전하게 복귀한다.
- STEP_UP reauthentication은 exact action target, expected version, payload digest와 이유를 다시 보여준다.

## 사용자·역할 관리

```text
User / status / roles / last access / pending request
Role detail: capabilities / risk / SOD conflicts / members / change history
Grant/revoke: target + role + duration + reason + approver + reauth
```

- 역할 변경은 self-approval 금지다.
- bulk permanent grant 금지, time-bound access를 기본으로 한다.
- 권한 없음 화면에서 private resource 제목·존재를 노출하지 않는다.

## 감사 로그

- actor, action, target type/id, request ID, policy decision, before/after hash, timestamp를 필터한다.
- 민감 body를 표시하지 않고 evidence/audit locator로 연결한다.
- export는 별도 capability, reason, scope, watermark/receipt를 요구한다.
- product analytics와 audit event를 동일 UI·retention으로 취급하지 않는다.
