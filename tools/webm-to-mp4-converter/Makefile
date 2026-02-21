PYTHON ?= python3
VENV_DIR ?= .venv
MODE ?= all
FILES ?=
JOBS ?=

.DEFAULT_GOAL := run

.PHONY: run

run:
	@set -e; \
	if [ "$(MODE)" != "all" ] && [ "$(MODE)" != "selected" ]; then \
		echo "Usage: make run MODE=all|selected [FILES='a.webm,b.webm'] [JOBS=2]"; \
		exit 1; \
	fi; \
	if [ "$(MODE)" = "selected" ] && [ -z "$(FILES)" ]; then \
		echo "MODE=selected requires FILES='a.webm,b.webm'"; \
		exit 1; \
	fi; \
	args="--mode $(MODE) --input-dir input_data --output-dir output_data"; \
	if [ -n "$(JOBS)" ]; then args="$$args --jobs $(JOBS)"; fi; \
	if [ "$(MODE)" = "selected" ]; then \
		OLD_IFS="$$IFS"; IFS=','; \
		for f in $(FILES); do args="$$args --file $$f"; done; \
		IFS="$$OLD_IFS"; \
	fi; \
	PYTHON="$(PYTHON)" VENV_DIR="$(VENV_DIR)" ./run.sh $$args
