PYTHON ?= python3
VENV_DIR ?= .venv
URL ?=
COOKIES_BROWSER ?=

.DEFAULT_GOAL := run

.PHONY: run

run:
	@if [ -z "$(URL)" ]; then \
		echo "Usage: make run URL='https://www.youtube.com/watch?v=...'" ; \
		exit 1; \
	fi
	@PYTHON="$(PYTHON)" VENV_DIR="$(VENV_DIR)" ./run.sh "$(URL)" $(if $(COOKIES_BROWSER),--cookies-from-browser "$(COOKIES_BROWSER)")
