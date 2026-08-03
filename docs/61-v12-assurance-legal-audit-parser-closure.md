# 61. v12 보증 수준·법률 Hold·감사 Export·실추출 검증 폐쇄

상태: **FINAL**  
사양 버전: **13.0.0**

## 내부 세션

`gurine_internal_session`은 하나의 canonical encrypted payload만 사용한다.

```text
v
typ
opaqueIdentitySessionToken
csrfToken
issuedAt
absoluteExpiresAt
csrfRotatedAt
```

BFF는 envelope을 복호화해 opaque token을 Private Identity API의 `opaqueSessionToken`으로 전달한다.
`sessionId`와 `userId`는 쿠키의 권위값으로 사용하지 않으며 Identity API가 token hash로 매 요청 확인한다.

## UI 상호작용과 보안 assurance

UI의 시각적 확인 강도와 인증 보증 수준을 분리한다.

```text
interaction_kind:
  NAVIGATION | DOWNLOAD | EXTERNAL_LINK | FORM_SUBMIT | COMMAND | DESTRUCTIVE_CONFIRMATION

assurance_level:
  ANONYMOUS_PROOF | SCOPED_TOKEN | ACTIVE_SESSION | RECENT_SESSION | STEP_UP
```

`DESTRUCTIVE_CONFIRMATION`은 Step-up을 자동 의미하지 않는다. 보안 권위는
`specs/auth/assurance-policy.yaml`과 command semantics이며 화면 action은 validator로 대조한다.

## Review 법률 Hold

`placeLegalHold`는 전용 명령이다. Review snapshot·case·expected case version·scope·authority reference·reason·optional expiry를 명시하고,
case aggregate를 compare-and-swap한 뒤 immutable legal hold를 생성한다. `submitReview`의 reject/changes-required로 암묵 해석하지 않는다.

## 감사 Export

민감 Audit 반출은 GET download가 아니다. `createAuditExport` command가 기간·typed scope·reason·watermark policy·expiry를 받아
immutable request와 bounded worker job을 생성한다. `getAuditExport` query는 상태와 만료 download link만 반환한다.

## Assertion 오류

Assertion reference verifier는 각 negative fixture의 public `expectedError` 또는 `expectedErrorOnAttempt`를 직접 읽는다.
내부 parsing/crypto 오류를 Service/Actor RFC 9457 error code로 매핑한 결과를 fixture와 비교한다.

## Parser/OCR

Reference harness는 8개 정책 format과 15개 fixture를 실제 추출·거부한다.

- CSV, XML, XLSX, DOCX, HWPX
- Digital PDF
- Scanned PDF (`pdftoppm` + Tesseract `kor+eng`)
- Binary HWP: 자동 추출 금지, trusted offline PDF/HWPX conversion 필요

정상·악성 fixture 모두 `specs/parsers/expected/*.extraction.json` golden output과 byte-stable semantic JSON 비교를 수행한다.
