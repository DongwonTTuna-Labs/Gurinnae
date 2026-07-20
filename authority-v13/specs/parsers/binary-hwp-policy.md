# Binary `.hwp` Policy

상태: **FINAL**

Legacy OLE Compound File `.hwp`는 first-party process에서 파싱하지 않는다. 원본 byte와 SHA-256을 보존하고 `BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION`으로 격리한다. 외부 자동 변환은 금지한다. 운영자가 신뢰된 offline 환경에서 PDF 또는 HWPX로 변환한 경우 변환본을 별도 SourceDocument로 수집하고 원본과 provenance로 연결한다.
