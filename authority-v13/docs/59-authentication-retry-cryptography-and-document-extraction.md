# 59. Authentication Retry, Cryptography and Document Extraction

상태: **FINAL**

`resolveInternalSession`은 session 상태만 반환한다. BFF는 실제 Control API 요청별 exact binding으로 `issueActorAssertion`을 호출한다. 고위험 command의 step-up authorization은 session, canonical action digest와 Idempotency-Key hash에 결합되고 5분 동안 최대 세 개의 새로운 Actor Assertion JTI를 발급한다. Control API는 원시 proof나 authorization token을 받지 않는다.

Session cookie, step-up authorization cookie와 민감 DB field는 ChaCha20-Poly1305 IETF를 사용한다. exact wire format, AAD, nonce, key rotation과 deterministic vectors는 `specs/cryptography/`가 권위다.

CSV, XML, XLSX, DOCX, HWPX, digital PDF와 scanned PDF parser/OCR은 exact version과 no-network sandbox를 사용하고 page/cell/paragraph provenance를 보존한다. DTD/entity, ZIP traversal/bomb, encrypted·oversized·corrupt input은 fail-closed다.
