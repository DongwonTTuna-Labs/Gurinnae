.PHONY: final-check validate-ui validate-api validate-database validate-architecture verify-postgres-runtime test-document-extractor test-document-extractor-runtime test-event-consumers-runtime test-analysis-runtime test-analysis-negative-runtime test-analysis-production-egress test-ingest-runtime test-scheduler-runtime test-procurement-runtime test-ui-e2e test-ui-visual test-runtime-quality test-rust-workspace test-sqlx-prepare manifest package-verify verify verify-authority verify-additive-hard-gates verify-acceptance-source run-acceptance-439 verify-execution-evidence verify-acceptance verify-bun verify-codegen verify-runtime verify-containers verify-prearchive verify-final source-archive clean-extraction-verify archive-check show-tech-baseline show-product-contract

PYTHON ?= python3
PYTHON_ENV := PYTHONDONTWRITEBYTECODE=1
AUTHORITY_ZIP ?= /home/dongwonttuna/.codex/attachments/29aa0c62-686a-450b-84aa-944e5cb7d47a/gurine-codex-authority-pack-v13.0.0-20260712.zip
AUTHORITY_VALIDATOR_ARGS = --rm --volume "$(CURDIR):/workspace" --volume "$(AUTHORITY_ZIP):/authority/gurine.zip:ro" --env GURINNAE_AUTHORITY_ZIP=/authority/gurine.zip --workdir /workspace
ACCEPTANCE_EVIDENCE_ROOT ?=
ACCEPTANCE_RUN_INDEX ?=
ACCEPTANCE_RUN_ID ?=
ACCEPTANCE_SOURCE_COMMIT ?=
ACCEPTANCE_SOURCE_TREE_SHA256 ?=
ACCEPTANCE_ARCHIVE ?=
ACCEPTANCE_EXTRACTION_RECEIPT ?=
ACCEPTANCE_EXTRACTION_RECEIPT_SHA256 ?=

final-check:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --strict

validate-ui:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section ui --strict

validate-api:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section api --strict

validate-database:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section database --strict

validate-architecture:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_final_spec.py --section architecture --strict


verify-postgres-runtime:
	bash -euo pipefail -c 'before="$$(PYTHONDONTWRITEBYTECODE=1 $(PYTHON) scripts/authority_tree_digest.py)"; out="$$(mktemp -t gurine-pg-runtime-XXXXXX.json)"; trap "rm -f $$out; rm -rf verification/postgres-runtime/node_modules" EXIT; cd verification/postgres-runtime; npm ci --ignore-scripts --no-audit --no-fund; npm run verify -- --output "$$out"; cd ../..; PYTHONDONTWRITEBYTECODE=1 $(PYTHON) scripts/compare_postgres_runtime.py "$$out"; after="$$(PYTHONDONTWRITEBYTECODE=1 $(PYTHON) scripts/authority_tree_digest.py)"; test "$$before" = "$$after"; sha256sum --check MANIFEST.sha256'

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

test-ui-e2e:
	bun run build
	bun run test:e2e

test-ui-visual:
	bun run build
	bun run test:visual

test-runtime-quality:
	bash scripts/test-runtime-quality.sh

test-rust-workspace:
	$(MAKE) test-runtime-quality
	docker build --target rust-workspace-test --output type=cacheonly -f infra/docker/rust-service/Dockerfile .

test-sqlx-prepare:
	bash scripts/test-sqlx-prepare.sh

verify-authority:
	docker build --target authority-validator -f infra/docker/rust-service/Dockerfile -t gurine-authority-validator:13.0.0 .
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validate_final_spec.py --strict
	sha256sum --quiet --check MANIFEST.sha256

verify-additive-hard-gates: verify-authority
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/generate_supplemental_execution_mapping.py
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/generate_effective_execution_registry.py
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/generate_acceptance_design_registry.py
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validation/effective_acceptance.py --self-test
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validation/effective_acceptance.py --mode contract
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validation/design_freeze.py --self-test
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validation/design_freeze.py --mode lint

verify-acceptance-source: verify-additive-hard-gates
	docker run $(AUTHORITY_VALIDATOR_ARGS) gurine-authority-validator:13.0.0 python -B scripts/validation/effective_acceptance.py --mode source

run-acceptance-439: verify-acceptance-source
	@test -n "$(ACCEPTANCE_EVIDENCE_ROOT)" || { printf '%s\n' 'ACCEPTANCE_EVIDENCE_ROOT is required'; exit 2; }
	@test -n "$(ACCEPTANCE_RUN_ID)" || { printf '%s\n' 'ACCEPTANCE_RUN_ID is required'; exit 2; }
	@test -n "$(ACCEPTANCE_SOURCE_COMMIT)" || { printf '%s\n' 'ACCEPTANCE_SOURCE_COMMIT is required'; exit 2; }
	@test -n "$(ACCEPTANCE_SOURCE_TREE_SHA256)" || { printf '%s\n' 'ACCEPTANCE_SOURCE_TREE_SHA256 is required'; exit 2; }
	@test -n "$(ACCEPTANCE_ARCHIVE)" || { printf '%s\n' 'ACCEPTANCE_ARCHIVE is required'; exit 2; }
	@test -n "$(ACCEPTANCE_EXTRACTION_RECEIPT)" || { printf '%s\n' 'ACCEPTANCE_EXTRACTION_RECEIPT is required'; exit 2; }
	@test -n "$(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)" || { printf '%s\n' 'ACCEPTANCE_EXTRACTION_RECEIPT_SHA256 is required'; exit 2; }
	@rustc --version | grep --fixed-strings 'rustc 1.97.0'
	@cargo nextest --version | grep --fixed-strings 'cargo-nextest 0.9.140'
	@test "$$(bun --version)" = '1.3.14'
	@docker compose version >/dev/null
	PYTHONPATH=scripts $(PYTHON_ENV) $(PYTHON) -B scripts/run_acceptance.py \
		--evidence-root "$(ACCEPTANCE_EVIDENCE_ROOT)" \
		--run-id "$(ACCEPTANCE_RUN_ID)" \
		--source-commit "$(ACCEPTANCE_SOURCE_COMMIT)" \
		--source-tree-sha256 "$(ACCEPTANCE_SOURCE_TREE_SHA256)" \
		--archive "$(ACCEPTANCE_ARCHIVE)" \
		--extraction-receipt "$(ACCEPTANCE_EXTRACTION_RECEIPT)" \
		--extraction-receipt-sha256 "$(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)"

verify-execution-evidence: run-acceptance-439
	docker run --rm \
		--env GURINNAE_SOURCE_COMMIT="$(ACCEPTANCE_SOURCE_COMMIT)" \
		--env GURINNAE_SOURCE_TREE_SHA256="$(ACCEPTANCE_SOURCE_TREE_SHA256)" \
		--env GURINNAE_ARCHIVE_SHA256="$$(sha256sum "$(ACCEPTANCE_ARCHIVE)" | cut -d' ' -f1)" \
		--env GURINNAE_EXTRACTION_RECEIPT_SHA256="$(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)" \
		--env GURINNAE_EXTRACTION_RECEIPT="/acceptance-evidence/$(ACCEPTANCE_RUN_ID)/common/extraction-receipt.json" \
		--env GURINNAE_AUTHORITY_ZIP=/authority/gurine.zip \
		--volume "$(CURDIR):/workspace:ro" \
		--volume "$(AUTHORITY_ZIP):/authority/gurine.zip:ro" \
		--volume "$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence:ro" \
		--workdir /workspace \
		gurine-authority-validator:13.0.0 \
		python -B scripts/validation/effective_acceptance.py --mode evidence \
		--evidence-root /acceptance-evidence \
		--run-index "$(ACCEPTANCE_RUN_ID)/run-index.json"

verify-acceptance: verify-execution-evidence
	@printf '439 exact acceptance scenarios and sealed external evidence: PASS\n'

verify-bun:
	docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --volume "$(CURDIR):/workspace" --workdir /workspace oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f sh -euc 'bun install --frozen-lockfile && bunx biome check . && bun run check && bun run test && bun run build'

verify-codegen:
	bun run scripts/generate-clients.ts --check
	$(PYTHON_ENV) $(PYTHON) -B scripts/verify_generated_responses.py

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

verify-prearchive: verify-additive-hard-gates verify-acceptance-source test-rust-workspace test-sqlx-prepare verify-bun verify-codegen verify-runtime verify-containers test-ui-e2e test-ui-visual
	@printf 'all static, source, runtime, container, recovery and UI prearchive gates: PASS\n'

verify-final: verify-acceptance test-rust-workspace test-sqlx-prepare verify-bun verify-codegen verify-runtime verify-containers test-ui-e2e test-ui-visual
	@printf 'all authority, source, runtime, container, recovery and UI hard gates: PASS\n'

source-archive:
	$(PYTHON_ENV) $(PYTHON) -B scripts/create_source_archive.py

clean-extraction-verify:
	$(PYTHON_ENV) $(PYTHON) -B scripts/verify_source_archive.py

manifest:
	$(PYTHON_ENV) $(PYTHON) scripts/generate_manifest.py

package-verify: final-check
	sha256sum --check MANIFEST.sha256

verify: package-verify

archive-check:
	$(PYTHON_ENV) $(PYTHON) scripts/verify_release_archives.py

show-tech-baseline:
	$(PYTHON) -c 'import yaml; print(yaml.safe_dump(yaml.safe_load(open("specs/architecture/technology-baseline.yaml")), sort_keys=False, allow_unicode=True))'

show-product-contract:
	$(PYTHON) -c 'import yaml; print(yaml.safe_dump(yaml.safe_load(open("specs/product/final-product-contract.yaml")), sort_keys=False, allow_unicode=True))'
