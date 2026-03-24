# CDK Makefile — Common targets for CDK projects
#
# Usage:
#   make synth              Synthesize CloudFormation template
#   make diff               Show pending changes
#   make deploy             Deploy all stacks
#   make deploy-dev         Deploy to dev stage
#   make deploy-prod        Deploy to prod (with approval)
#   make destroy            Destroy all stacks (with confirmation)
#   make test               Run unit tests
#   make lint               Lint TypeScript code
#   make bootstrap          Bootstrap CDK in target account
#   make clean              Clean build artifacts
#
# Configuration:
#   Override variables via environment or command line:
#   make deploy STACK=MyStack REGION=us-west-2

# --- Configuration ---
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Project settings (override as needed)
STACK         ?=
REGION        ?= us-east-1
ACCOUNT       ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
QUALIFIER     ?= hnb659fds

# CDK command
CDK           := npx cdk
CDK_OPTS      := $(if $(STACK),$(STACK),)

# --- Build ---

.PHONY: build
build: ## Compile TypeScript
	npm run build

.PHONY: watch
watch: ## Watch mode — recompile on changes
	npm run watch

.PHONY: clean
clean: ## Clean build artifacts
	rm -rf cdk.out lib/*.js lib/*.d.ts lib/**/*.js lib/**/*.d.ts
	@echo "✅ Cleaned build artifacts"

# --- CDK Commands ---

.PHONY: synth
synth: build ## Synthesize CloudFormation templates
	$(CDK) synth $(CDK_OPTS)

.PHONY: diff
diff: build ## Show pending changes vs deployed
	$(CDK) diff $(CDK_OPTS)

.PHONY: deploy
deploy: build ## Deploy stack(s)
	$(CDK) deploy $(CDK_OPTS) --require-approval broadening

.PHONY: deploy-dev
deploy-dev: build ## Deploy to dev stage
	$(CDK) deploy $(CDK_OPTS) -c stage=dev --require-approval never

.PHONY: deploy-staging
deploy-staging: build ## Deploy to staging stage
	$(CDK) deploy $(CDK_OPTS) -c stage=staging --require-approval broadening

.PHONY: deploy-prod
deploy-prod: build ## Deploy to prod stage (requires approval)
	$(CDK) deploy $(CDK_OPTS) -c stage=prod --require-approval always

.PHONY: deploy-all
deploy-all: build ## Deploy all stacks in parallel
	$(CDK) deploy --all --concurrency 3 --require-approval broadening

.PHONY: destroy
destroy: ## Destroy stack(s) — prompts for confirmation
	@echo "⚠️  This will DESTROY resources. Press Ctrl+C to cancel."
	@read -p "Type stack name to confirm: " confirm; \
	$(CDK) destroy $(CDK_OPTS)

.PHONY: hotswap
hotswap: build ## Fast-deploy Lambda/ECS changes (dev only!)
	$(CDK) deploy $(CDK_OPTS) --hotswap -c stage=dev

.PHONY: cdk-watch
cdk-watch: ## Watch mode — auto-deploy on file change (dev only!)
	$(CDK) watch $(CDK_OPTS) -c stage=dev

.PHONY: ls
ls: ## List all stacks in the app
	$(CDK) ls

# --- Bootstrap ---

.PHONY: bootstrap
bootstrap: ## Bootstrap CDK in current account/region
	$(CDK) bootstrap aws://$(ACCOUNT)/$(REGION)

.PHONY: bootstrap-cross-account
bootstrap-cross-account: ## Bootstrap for cross-account pipeline
	@read -p "Target account ID: " target_account; \
	read -p "Pipeline account ID: " pipeline_account; \
	$(CDK) bootstrap aws://$$target_account/$(REGION) \
		--trust $$pipeline_account \
		--cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
		--qualifier $(QUALIFIER)

# --- Testing ---

.PHONY: test
test: ## Run unit tests
	npm test

.PHONY: test-watch
test-watch: ## Run tests in watch mode
	npx jest --watch

.PHONY: test-coverage
test-coverage: ## Run tests with coverage report
	npx jest --coverage

.PHONY: test-update-snapshots
test-update-snapshots: ## Update test snapshots
	npx jest --updateSnapshot

# --- Linting ---

.PHONY: lint
lint: ## Lint TypeScript code
	npx eslint 'lib/**/*.ts' 'bin/**/*.ts' 'test/**/*.ts' --fix

.PHONY: lint-check
lint-check: ## Check linting without fixes
	npx eslint 'lib/**/*.ts' 'bin/**/*.ts' 'test/**/*.ts'

.PHONY: typecheck
typecheck: ## Run TypeScript type checking
	npx tsc --noEmit

# --- CI/CD Helpers ---

.PHONY: ci
ci: ## Full CI pipeline: lint, build, test, synth
	npm ci
	$(MAKE) lint-check
	$(MAKE) build
	$(MAKE) test
	$(MAKE) synth

.PHONY: diff-check
diff-check: build ## Run diff check (fail on destructive changes)
	@echo "Running CDK diff check..."
	@$(CDK) diff $(CDK_OPTS) 2>&1 | tee /tmp/cdk-diff.out; \
	if grep -qiE '^\[-\]|replace' /tmp/cdk-diff.out; then \
		echo "❌ Destructive changes detected!"; \
		exit 1; \
	else \
		echo "✅ No destructive changes."; \
	fi

# --- Utilities ---

.PHONY: context-clear
context-clear: ## Clear cached context values
	$(CDK) context --clear

.PHONY: doctor
doctor: ## Run CDK doctor diagnostics
	$(CDK) doctor

.PHONY: deps-update
deps-update: ## Update CDK and dependencies
	npm update aws-cdk-lib constructs
	npm update
	@echo "✅ Dependencies updated. Run 'make test' to verify."

.PHONY: template
template: synth ## View synthesized CloudFormation template
	@if [ -n "$(STACK)" ]; then \
		cat cdk.out/$(STACK).template.json | python3 -m json.tool; \
	else \
		echo "Specify STACK=StackName to view a specific template."; \
		echo "Available:"; \
		ls cdk.out/*.template.json 2>/dev/null | sed 's|cdk.out/||;s|.template.json||' | sed 's/^/  /'; \
	fi

# --- Help ---

.PHONY: help
help: ## Show this help message
	@echo "CDK Makefile Targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  STACK=StackName     Target specific stack"
	@echo "  REGION=us-west-2    Override region (default: us-east-1)"
	@echo "  ACCOUNT=123456      Override account"
