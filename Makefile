RUBY ?= ruby

.DEFAULT_GOAL := help

.PHONY: help validate-manifests registry resolve test-registry route route-text detect-gaps dispatch agent test

help:
	@echo "Targets:"
	@echo "  make validate-manifests        Validate tools/*/tool.yaml against schema"
	@echo "  make registry                  Build state/registry-cache.json"
	@echo "  make resolve CAP=domain.action Resolve best tool for capability from cache"
	@echo "  make test-registry             Run registry unit tests"
	@echo "  make route REQUEST=path        Build workflow plan JSON from request YAML/JSON"
	@echo "  make route-text TEXT='...'     Build workflow plan JSON from raw user text"
	@echo "  make detect-gaps PLAN=path     Enrich plan with tools and gap_report from registry"
	@echo "   TEXT='...'       Route + detect-gaps + preview (set EXECUTE=1 to run)"
	@echo "  make agent TEXT='...'          Autonomous agent entrypoint (use LLM_LOG=1 to print raw LLM request/response sections)"
	@echo "  make test                      Run all unit tests (registry + skills)"

validate-manifests:
	@$(RUBY) scripts/tool_registry.rb validate

registry:
	@$(RUBY) scripts/tool_registry.rb build --output state/registry-cache.json

resolve:
	@if [ -z "$(CAP)" ]; then echo "Usage: make resolve CAP=domain.action" >&2; exit 1; fi
	@$(RUBY) scripts/tool_registry.rb resolve "$(CAP)" --from-cache state/registry-cache.json

test-registry:
	@$(RUBY) scripts/tool_registry_test.rb

route:
	@if [ -z "$(REQUEST)" ]; then echo "Usage: make route REQUEST=path [OUTPUT=path]" >&2; exit 1; fi
	@$(RUBY) skills/request-router/request_router.rb route --request "$(REQUEST)" $(if $(OUTPUT),--output "$(OUTPUT)",) --pretty

route-text:
	@if [ -z "$(TEXT)" ]; then echo "Usage: make route-text TEXT='...'" >&2; exit 1; fi
	@$(RUBY) skills/request-router/request_router.rb route-text --text "$(TEXT)" --pretty

detect-gaps:
	@if [ -z "$(PLAN)" ]; then echo "Usage: make detect-gaps PLAN=path [OUTPUT=path] [REGISTRY=path]" >&2; exit 1; fi
	@$(RUBY) skills/gap-detector/gap_detector.rb detect --plan "$(PLAN)" $(if $(REGISTRY),--registry "$(REGISTRY)",) $(if $(OUTPUT),--output "$(OUTPUT)",) --pretty

dispatch:
	@if [ -z "$(TEXT)" ]; then echo "Usage: make dispatch TEXT='...' [EXECUTE=1] [DRY_RUN=1]" >&2; exit 1; fi
	@$(RUBY) scripts/dispatch.rb run --text "$(TEXT)" $(if $(EXECUTE),--execute,) $(if $(DRY_RUN),--dry-run,) --pretty

agent:
	@if [ -z "$(TEXT)" ]; then echo "Usage: make agent TEXT='...' [PREVIEW=1] [LLM_LOG=1]" >&2; exit 1; fi
	@if [ -n "$(EXECUTE)$(DRY_RUN)" ]; then echo "Note: make agent ignores EXECUTE/DRY_RUN; use PREVIEW=1 for preview mode." >&2; fi
	@set +e; \
	$(RUBY) scripts/agent.rb --text "$(TEXT)" $(if $(PREVIEW),--no-execute --dry-run,) $(if $(LLM_LOG),--llm-log,) --output pretty; \
	code=$$?; \
	if [ $$code -eq 2 ]; then \
		echo "Итог: задача выполнена частично (не хватает capability/утилит)."; \
		exit 0; \
	fi; \
	if [ $$code -ne 0 ]; then \
		echo "Итог: агент завершился с ошибкой (код=$$code)."; \
	fi; \
	exit $$code

test:
	@$(RUBY) scripts/tool_registry_test.rb
	@$(RUBY) scripts/request_router_test.rb
	@$(RUBY) scripts/gap_detector_test.rb
	@$(RUBY) scripts/workflow_executor_test.rb
	@$(RUBY) scripts/dispatch_test.rb
	@$(RUBY) scripts/llm_client_test.rb
	@$(RUBY) scripts/policy_engine_test.rb
	@$(RUBY) scripts/agent_test.rb
