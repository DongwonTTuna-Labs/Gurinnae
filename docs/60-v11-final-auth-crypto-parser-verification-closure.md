# 60. v11 최종 인증·암호화·문서추출·검증 폐쇄

상태: **HISTORICAL / SUPERSEDED BY v12**
현재 권위 문서: `docs/61-v12-assurance-legal-audit-parser-closure.md`

## 내부 인증

세션 해석은 Actor Assertion을 발급하지 않는다. Review Console BFF는 exact Control API method, normalized path, canonical query hash, body hash, content type, operation ID, required capability와 Idempotency-Key hash를 알고 난 뒤 `issueActorAssertion`을 호출한다.

고위험 작업은 typed action descriptor로 시작한다. BFF가 Idempotency-Key를 생성하고 canonical ActionAuthorizationContext와 action digest를 만든다. Step-up callback은 Actor Assertion을 직접 발급하지 않고 5분·최대 3회 발급 가능한 bounded authorization을 만든다. Raw authorization은 encrypted host-only cookie에만 있고 Control API로 전달되지 않는다.

## 암호화

Session, step-up transaction, step-up authorization과 DB field envelope은 ChaCha20-Poly1305 IETF, 32-byte key, 12-byte random nonce, explicit AAD, current/previous key rotation과 deterministic vectors를 사용한다.

## 문서 추출

CSV/XML/XLSX/DOCX/HWPX/digital PDF/scanned PDF의 parser와 버전을 고정한다. PDF OCR은 pdftoppm과 Tesseract를 network-disabled sandbox child process로 실행한다. ZIP traversal, high compression ratio, XXE, truncated file과 resource-limit fixture를 hard gate로 둔다.

## 권위 검증

PostgreSQL runtime result는 authority tree 밖의 임시 경로에 기록한다. Stable baseline comparison과 실행 전후 authority-tree digest equality를 모두 통과해야 하며 verifier 실행이 tracked file을 바꿀 수 없다.
