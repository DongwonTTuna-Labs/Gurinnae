# 명세 패키지 도구와 production runtime의 구분

## 1. 목적

이 패키지는 애플리케이션 구현 전에도 JSON Schema, fixture, OpenAPI baseline, Markdown reference, manifest를 검사해야 한다. 이를 위해 작은 Python 스크립트를 제공한다.

## 2. 허용 범위

```text
scripts/validate_spec_pack.py
scripts/generate_manifest.py
requirements-spec.txt
```

은 **명세 패키지 제작·배포 검사 도구**다. 다음 의미가 아니다.

- production Python service 허용
- ingestion/analysis Python worker 허용
- Python domain model 허용
- production runtime dependency 허용

## 3. Production 금지

최종 Cargo/Bun workspace의 다음 경로에 Python runtime을 추가하지 않는다.

```text
apps/
services/
crates/
packages/
infra/runtime images
```

후속 ML/OCR library로 Python이 꼭 필요하면 별도 ADR에서 network/DB/write/publication 권한이 없는 isolated sidecar contract를 설계하고 사람 승인을 받아야 한다.

## 4. Validator 책임

- required package inventory
- syntax/schema
- fixture graph
- design OpenAPI
- technology baseline
- forbidden active technology
- blueprint consistency
- acceptance coverage
- link/context volume

Validator가 실제 Rust/Bun/Docker runtime gate를 대신하지 않는다.

## 5. Manifest

`MANIFEST.sha256`는 package-relative file hash를 기록한다. Archive 제작 후 fresh extraction에서 다시 검증한다. Manifest generation은 timestamps를 넣지 않아 deterministic text를 유지한다.

## 6. Dependency

Spec tooling dependency는 `requirements-spec.txt`에 bounded range로 둔다. 이 dependency는 production SBOM/runtime에 포함하지 않는다.
