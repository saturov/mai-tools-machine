PYTHON ?= python3
VENV_DIR ?= .venv
FILE ?=
FOLDER_ID ?=

.DEFAULT_GOAL := run

.PHONY: run

run:
	@if [ -z "$(FILE)" ] || [ -z "$(FOLDER_ID)" ]; then \
		echo "Usage: make run FILE='/path/to/file' FOLDER_ID='...'" ; \
		exit 1; \
	fi
	@PYTHON="$(PYTHON)" VENV_DIR="$(VENV_DIR)" ./run.sh --file-path "$(FILE)" --folder-id "$(FOLDER_ID)"

