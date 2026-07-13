.PHONY: final-check validate-ui validate-api validate-database validate-architecture verify-postgres-runtime test-document-extractor test-document-extractor-runtime test-event-consumers-runtime test-analysis-runtime test-analysis-negative-runtime test-analysis-production-egress test-ingest-runtime test-scheduler-runtime test-ui-e2e test-ui-visual test-rust-workspace test-sqlx-prepare manifest package-verify verify verify-authority verify-bun verify-codegen verify-runtime verify-containers verify-final source-archive clean-extraction-verify archive-check show-tech-baseline show-product-contract

PYTHON ?= python3
PYTHON_ENV := PYTHONDONTWRITEBYTECODE=1

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

test-ui-e2e:
	bun run build
	bun run test:e2e

test-ui-visual:
	bun run build
	bun run test:visual

test-rust-workspace:
	docker build --target rust-workspace-test --output type=cacheonly -f infra/docker/rust-service/Dockerfile .

test-sqlx-prepare:
	bash scripts/test-sqlx-prepare.sh

verify-authority:
	docker build --target authority-validator -f infra/docker/rust-service/Dockerfile -t gurine-authority-validator:13.0.0 .
	docker run --rm --volume "$(CURDIR):/workspace" --workdir /workspace gurine-authority-validator:13.0.0 python -B scripts/validate_final_spec.py --strict
	sha256sum --quiet --check MANIFEST.sha256

verify-bun:
	docker run --rm --user "$$(id -u):$$(id -g)" --env HOME=/tmp --volume "$(CURDIR):/workspace" --workdir /workspace oven/bun:1.3.14-debian@sha256:9dba1a1b43ce28c9d7931bfc4eb00feb63b0114720a0277a8f939ae4dfc9db6f sh -euc 'bun install --frozen-lockfile && bunx biome check . && bun run check && bun run test && bun run build'

verify-codegen:
	@bash -euo pipefail -c 'paths=(specs/generated packages/api-client-control/src/generated packages/api-client-identity-internal/src/generated packages/api-client-public/src/generated packages/api-client-submission/src/generated); before="$$(find "$${paths[@]}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"; bun run codegen; after="$$(find "$${paths[@]}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"; test "$$before" = "$$after"'

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

verify-final: verify-authority test-rust-workspace test-sqlx-prepare verify-bun verify-codegen verify-runtime verify-containers test-ui-e2e test-ui-visual
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
