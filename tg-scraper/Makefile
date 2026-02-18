PYTHON := python3
VENV_DIR := .venv
PIP := $(VENV_DIR)/bin/pip
PY := $(VENV_DIR)/bin/python

.PHONY: help venv install run clean

help:
	@echo "Targets:"
	@echo "  make venv      - создать venv (.venv)"
	@echo "  make install   - установить зависимости в venv"
	@echo "  make run       - запустить скрипт tg-scraper.py через venv"
	@echo "  make clean     - удалить venv и артефакты"

$(VENV_DIR)/.deps-installed: requirements.txt
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt
	@touch "$(VENV_DIR)/.deps-installed"

venv:
	@if [ ! -x "$(PY)" ] || ! "$(PY)" -V >/dev/null 2>&1; then \
		echo "Пересоздаю venv: $(VENV_DIR)"; \
		rm -rf "$(VENV_DIR)"; \
		$(PYTHON) -m venv "$(VENV_DIR)"; \
	fi
	@$(MAKE) --no-print-directory "$(VENV_DIR)/.deps-installed"
	@echo "venv готов: $(VENV_DIR)"

install: venv
	@echo "Зависимости установлены"

# Пробрасываем все аргументы после -- в скрипт, например:
# make run -- --channel @my_channel --output out.txt
run: venv
	$(PY) tg-scraper.py $(filter-out $@,$(MAKECMDGOALS))

%:
	@:

clean:
	rm -rf $(VENV_DIR)
