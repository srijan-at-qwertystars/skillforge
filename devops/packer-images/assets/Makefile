# =============================================================================
# Makefile — Packer project automation
#
# Usage:
#   make init          Install required plugins
#   make fmt           Format all HCL files
#   make validate      Validate template (dev by default)
#   make build         Build image (dev by default)
#   make build-prod    Build production image
#   make scan          Scan the last built AMI
#   make clean         Remove build artifacts
#   make inspect       Show template components
#
# Override defaults:
#   make build ENV=staging
#   make build VAR_FILE=custom.pkrvars.hcl
#   make scan AMI_ID=ami-12345678
# =============================================================================

.PHONY: init fmt validate build build-dev build-staging build-prod inspect scan clean debug help

# --- Configuration ---
PACKER        ?= packer
ENV           ?= dev
VAR_FILE      ?= $(ENV).pkrvars.hcl
PACKER_DIR    ?= .
MANIFEST      ?= manifests/manifest.json
REPORT_DIR    ?= scan-reports
AMI_ID        ?= $(shell [ -f $(MANIFEST) ] && jq -r '.builds[-1].artifact_id' $(MANIFEST) | cut -d: -f2 || echo "")
GIT_SHA       ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Extra vars passed to every build
EXTRA_VARS    ?= -var "git_sha=$(GIT_SHA)"

# --- Targets ---

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

init: ## Install required Packer plugins
	$(PACKER) init $(PACKER_DIR)

fmt: ## Format all HCL files
	$(PACKER) fmt -recursive $(PACKER_DIR)

fmt-check: ## Check formatting without modifying files
	$(PACKER) fmt -check -diff -recursive $(PACKER_DIR)

validate: init ## Validate template syntax and configuration
	$(PACKER) validate -var-file=$(VAR_FILE) $(EXTRA_VARS) $(PACKER_DIR)
	@echo "✅ Validation passed"

build: validate ## Build image (use ENV=dev|staging|production)
	$(PACKER) build -var-file=$(VAR_FILE) $(EXTRA_VARS) -color=false $(PACKER_DIR)
	@echo ""
	@echo "✅ Build complete"
	@[ -f $(MANIFEST) ] && echo "AMI: $$(jq -r '.builds[-1].artifact_id' $(MANIFEST))" || true

build-dev: ## Build dev image
	$(MAKE) build ENV=dev

build-staging: ## Build staging image
	$(MAKE) build ENV=staging

build-prod: ## Build production image
	$(MAKE) build ENV=production

inspect: ## Show template components
	$(PACKER) inspect $(PACKER_DIR)

scan: ## Security scan the last built AMI
	@if [ -z "$(AMI_ID)" ]; then \
		echo "Error: No AMI_ID. Build first or set AMI_ID=ami-xxx"; \
		exit 1; \
	fi
	@echo "Scanning AMI: $(AMI_ID)"
	./scripts/scan-image.sh --ami-id $(AMI_ID) --report-dir $(REPORT_DIR)

clean: ## Remove build artifacts and caches
	rm -rf manifests/*.json
	rm -rf $(REPORT_DIR)
	rm -rf packer_cache/
	rm -f *.log crash.log
	@echo "✅ Cleaned"

debug: init ## Build with debug logging and pause on error
	PACKER_LOG=1 PACKER_LOG_PATH=packer-debug.log \
		$(PACKER) build -var-file=$(VAR_FILE) $(EXTRA_VARS) -on-error=ask $(PACKER_DIR)

console: init ## Open Packer interactive console
	$(PACKER) console $(PACKER_DIR)

# --- Convenience ---

.DEFAULT_GOAL := help
