.PHONY: final-check validate-ui validate-api validate-database validate-architecture verify-postgres-runtime test-document-extractor test-document-extractor-runtime test-event-consumers-runtime test-analysis-runtime test-analysis-negative-runtime test-analysis-production-egress test-ingest-runtime test-scheduler-runtime test-procurement-runtime build-ui test-ui-e2e test-ui-visual test-runtime-quality test-rust-workspace test-sqlx-prepare verify verify-specs run-acceptance-439 verify-execution-evidence verify-acceptance verify-bun verify-codegen verify-runtime verify-containers verify-final source-archive clean-extraction-verify archive-check show-tech-baseline show-product-contract

PYTHON ?= python3
PYTHON_ENV := PYTHONDONTWRITEBYTECODE=1
ACCEPTANCE_EVIDENCE_ROOT ?=
ACCEPTANCE_RUN_ID ?=
ACCEPTANCE_SOURCE_COMMIT ?=
ACCEPTANCE_SOURCE_TREE_SHA256 ?=
ACCEPTANCE_ARCHIVE ?=
ACCEPTANCE_EXTRACTION_RECEIPT ?=
ACCEPTANCE_EXTRACTION_RECEIPT_SHA256 ?=
ACCEPTANCE_OVERRIDE_ARGS = $(strip \
	$(if $(strip $(ACCEPTANCE_EVIDENCE_ROOT)),--evidence-root "$(ACCEPTANCE_EVIDENCE_ROOT)") \
	$(if $(strip $(ACCEPTANCE_RUN_ID)),--run-id "$(ACCEPTANCE_RUN_ID)") \
	$(if $(strip $(ACCEPTANCE_SOURCE_COMMIT)),--source-commit "$(ACCEPTANCE_SOURCE_COMMIT)") \
	$(if $(strip $(ACCEPTANCE_SOURCE_TREE_SHA256)),--source-tree-sha256 "$(ACCEPTANCE_SOURCE_TREE_SHA256)") \
	$(if $(strip $(ACCEPTANCE_ARCHIVE)),--archive "$(ACCEPTANCE_ARCHIVE)") \
	$(if $(strip $(ACCEPTANCE_EXTRACTION_RECEIPT)),--extraction-receipt "$(ACCEPTANCE_EXTRACTION_RECEIPT)") \
	$(if $(strip $(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)),--extraction-receipt-sha256 "$(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)"))

final-check: verify-specs

validate-ui:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section ui --strict

validate-api:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section api --strict

validate-database:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section database --strict

validate-architecture:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section architecture --strict


verify-postgres-runtime:
	bash -euo pipefail -c 'out="$$(mktemp -t gurine-pg-runtime-XXXXXX.json)"; trap "rm -f $$out; rm -rf verification/postgres-runtime/node_modules" EXIT; cd verification/postgres-runtime; npm ci --ignore-scripts --no-audit --no-fund; npm run verify -- --output "$$out"; cd ../..; PYTHONDONTWRITEBYTECODE=1 $(PYTHON) scripts/compare_postgres_runtime.py "$$out"'

test-document-extractor:
	docker build --target document-extractor-test -f infra/docker/rust-service/Dockerfile -t gurine-document-extractor-test:25.06.0-5.5.0 .

test-document-extractor-runtime:
	bash scripts/test-document-extractor-runtime.sh

test-event-consumers-runtime:
	bash scripts/test-event-consumers-runtime.sh

test-analysis-runtime:
	bash scripts/test-analysis-runtime.sh

test-analysis-negative-runtime:
	bash scripts/test-analysis-negative-runtime.sh

test-analysis-production-egress:
	bash scripts/test-analysis-production-egress.sh

test-ingest-runtime:
	bash scripts/test-ingest-runtime.sh

test-scheduler-runtime:
	bash scripts/test-scheduler-runtime.sh

test-procurement-runtime:
	bash scripts/test-procurement-runtime.sh

build-ui:
	bun run build

test-ui-e2e: build-ui
	bun run test:e2e

test-ui-visual: build-ui
	bun run test:visual

test-runtime-quality:
	bash scripts/test-runtime-quality.sh

test-rust-workspace:
	$(MAKE) test-runtime-quality
	docker build --target rust-workspace-test --output type=cacheonly -f infra/docker/rust-service/Dockerfile .
	bash scripts/test-rust-workspace-runtime.sh

test-sqlx-prepare:
	bash scripts/test-sqlx-prepare.sh

verify-specs:
	docker build --target authority-validator -f infra/docker/rust-service/Dockerfile -t gurine-spec-validator:13.0.0 .
	docker run --rm --network none --user "$$(id -u):$$(id -g)" --env HOME=/tmp --env PYTHONDONTWRITEBYTECODE=1 --volume "$(CURDIR):/workspace" --workdir /workspace gurine-spec-validator:13.0.0 python -B scripts/validate_final_spec.py --strict
	$(PYTHON_ENV) $(PYTHON) -B scripts/verify_migrations.py
	$(PYTHON_ENV) $(PYTHON) -B scripts/validation/effective_acceptance.py --self-test
	$(PYTHON_ENV) $(PYTHON) -B scripts/validation/effective_acceptance.py --mode source
	$(PYTHON_ENV) $(PYTHON) -B scripts/validation/design_freeze.py --self-test
	$(PYTHON_ENV) $(PYTHON) -B scripts/validation/design_freeze.py --mode lint

run-acceptance-439: verify-specs
	@rustc --version | grep --fixed-strings 'rustc 1.97.0'
	@cargo nextest --version | grep --fixed-strings 'cargo-nextest 0.9.140'
	@test "$$(bun --version)" = '1.3.14'
	@docker compose version >/dev/null
	PYTHONPATH=scripts $(PYTHON_ENV) $(PYTHON) -B scripts/run_acceptance.py$(if $(ACCEPTANCE_OVERRIDE_ARGS), $(ACCEPTANCE_OVERRIDE_ARGS))

verify-execution-evidence: run-acceptance-439
	@printf 'runner-owned independent evidence validation: PASS\n'

verify-acceptance: verify-execution-evidence
	@printf '439 exact acceptance scenarios and sealed evidence: PASS\n'

verify-bun: build-ui
	docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --volume "$(CURDIR):/workspace" --workdir /workspace oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f sh -euc 'bun install --frozen-lockfile && bunx biome check . && bun run check && bun run test'

verify-codegen:
	bun run scripts/generate-clients.ts --check
	$(PYTHON_ENV) $(PYTHON) -B scripts/generate_addendum_samples.py --check
	$(PYTHON_ENV) $(PYTHON) -B scripts/verify_generated_responses.py
	$(PYTHON_ENV) $(PYTHON) -B scripts/generate_supplemental_execution_mapping.py --check
	$(PYTHON_ENV) $(PYTHON) -B scripts/generate_effective_execution_registry.py --check
	$(PYTHON_ENV) $(PYTHON) -B scripts/generate_acceptance_design_registry.py --check
	bash -euo pipefail -c 'contracts="packages/ui/src/generated-screen-contracts.ts"; projections="packages/ui/src/generated-screen-projections.ts"; snapshot="$$(mktemp -d -t gurine-screen-codegen-XXXXXX)"; cleanup() { test ! -f "$$snapshot/contracts.ts" || cp "$$snapshot/contracts.ts" "$$contracts"; test ! -f "$$snapshot/projections.ts" || cp "$$snapshot/projections.ts" "$$projections"; rm -f "$$snapshot/contracts.ts" "$$snapshot/projections.ts"; rmdir "$$snapshot"; }; trap cleanup EXIT; trap "exit 130" HUP INT TERM; cp "$$contracts" "$$snapshot/contracts.ts"; cp "$$projections" "$$snapshot/projections.ts"; $(PYTHON_ENV) $(PYTHON) -B scripts/generate_typed_screen_registry.py; cmp "$$snapshot/contracts.ts" "$$contracts"; cmp "$$snapshot/projections.ts" "$$projections"; $(PYTHON_ENV) $(PYTHON) -B scripts/generate_typed_screen_registry.py; cmp "$$snapshot/contracts.ts" "$$contracts"; cmp "$$snapshot/projections.ts" "$$projections"'

verify-runtime: verify-postgres-runtime
	bash scripts/test-control-flow.sh
	bash scripts/test-submission-flow.sh
	bash scripts/test-identity-flow.sh
	bash scripts/test-public-flow.sh
	bash scripts/test-ingest-runtime.sh
	bash scripts/test-analysis-runtime.sh
	bash scripts/test-analysis-negative-runtime.sh
	bash scripts/test-analysis-production-egress.sh
	bash scripts/test-event-consumers-runtime.sh
	bash scripts/test-worker-failure-runtime.sh
	bash scripts/test-document-extractor-runtime.sh
	bash scripts/test-scheduler-runtime.sh
	bash scripts/test-egress-channels.sh

verify-containers:
	bash scripts/build-first-party-images.sh
	bash scripts/test-production-stack.sh
	bash scripts/test-backup-restore.sh

verify-final: verify-specs verify-codegen test-rust-workspace test-sqlx-prepare verify-bun verify-runtime verify-containers test-ui-e2e test-ui-visual
	@printf 'all specification, code generation, source, runtime, container, recovery and UI hard gates: PASS\n'

source-archive:
	$(PYTHON_ENV) $(PYTHON) -B scripts/create_source_archive.py

clean-extraction-verify:
	$(PYTHON_ENV) $(PYTHON) -B scripts/verify_source_archive.py

verify: verify-final

archive-check:
	$(PYTHON_ENV) $(PYTHON) scripts/verify_release_archives.py

show-tech-baseline:
	$(PYTHON) -c 'import yaml; print(yaml.safe_dump(yaml.safe_load(open("specs/architecture/technology-baseline.yaml")), sort_keys=False, allow_unicode=True))'

show-product-contract:
	$(PYTHON) -c 'import yaml; print(yaml.safe_dump(yaml.safe_load(open("specs/product/final-product-contract.yaml")), sort_keys=False, allow_unicode=True))'
