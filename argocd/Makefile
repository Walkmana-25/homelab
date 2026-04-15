.PHONY: lint check lint-yaml validate-kustomize validate-manifests help

SHELL := /bin/bash

# Directories to check
APPS_DIR := k3s/apps

# YAML files to lint
YAML_FILES := $(shell find . -name '*.yaml' -o -name '*.yml')

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

lint: lint-yaml validate-kustomize validate-manifests ## Run all linters and checks

lint-yaml: ## Lint all YAML files with yamllint
	@echo "=== Linting YAML files ==="
	yamllint -d "{extends: default, rules: {line-length: disable, truthy: {check-keys: false}, document-start: disable}}" $(YAML_FILES)

validate-kustomize: ## Validate kustomize builds for all environments
	@echo "=== Validating kustomize builds ==="
	@for dir in $(shell find $(APPS_DIR) -name 'kustomization.yaml' -exec dirname {} \;); do \
		echo "  Checking $$dir..."; \
		if ! kustomize build $$dir > /dev/null 2>&1; then \
			echo "  ERROR: kustomize build failed for $$dir"; \
			kustomize build $$dir; \
			exit 1; \
		fi; \
	done
	@echo "  All kustomize builds passed!"

validate-manifests: ## Validate ArgoCD Application manifests with kubeconform
	@echo "=== Validating Kubernetes manifests ==="
	@for dir in $(shell find $(APPS_DIR) -name 'kustomization.yaml' -exec dirname {} \;); do \
		echo "  Validating $$dir..."; \
		kustomize build $$dir | kubeconform \
			-schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/{{.NormalizedKubernetesVersion}}-standalone{{.KindSuffix}}/{{.ResourceKind}}.json' \
			-skip Application \
			-strict || exit 1; \
	done
	@echo "  All manifests validated!"

check: lint ## Alias for lint (runs all checks)

yaml-files: ## List all YAML files found
	@echo "YAML files found:"

