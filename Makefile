RUBY ?= ruby

.DEFAULT_GOAL := help

.PHONY: help validate-manifests registry resolve test-registry

help:
	@echo "Targets:"
	@echo "  make validate-manifests        Validate tools/*/tool.yaml against schema"
	@echo "  make registry                  Build state/registry-cache.json"
	@echo "  make resolve CAP=domain.action Resolve best tool for capability from cache"
	@echo "  make test-registry             Run registry unit tests"

validate-manifests:
	@$(RUBY) scripts/tool_registry.rb validate

registry:
	@$(RUBY) scripts/tool_registry.rb build --output state/registry-cache.json

resolve:
	@if [ -z "$(CAP)" ]; then echo "Usage: make resolve CAP=domain.action" >&2; exit 1; fi
	@$(RUBY) scripts/tool_registry.rb resolve "$(CAP)" --from-cache state/registry-cache.json

test-registry:
	@$(RUBY) scripts/tool_registry_test.rb

