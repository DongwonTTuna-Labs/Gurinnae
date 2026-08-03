.PHONY: final-check validate-ui validate-api validate-database validate-architecture verify-postgres-runtime manifest package-verify verify archive-check show-tech-baseline show-product-contract

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
