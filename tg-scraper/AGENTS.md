# AGENTS.md

## Purpose
Единая конфигурация развития проекта `tg-scraper` для Codex-агентов.

## Project Snapshot
- Type: CLI utility.
- Language: Python 3.10+.
- Core dependency: `telethon>=1.36`.
- Main script: `tg-scraper.py`.
- Current output format: plain TXT blocks (`export_<slug>.txt`).
- Build/run interface: `Makefile` (`make install`, `make run`, `make clean`).

## Product Goal
Надёжно выгружать историю Telegram-каналов в структурированный TXT без потери сообщений и с корректными метаданными:
- `ID`, `DATE_UTC`, `REACTIONS_TOTAL`, `REACTIONS_BREAKDOWN`, `COMMENTS_COUNT`, `HAS_IMAGE`, `HAS_ATTACH`, `TEXT`.

## Non-Goals (Until Explicitly Requested)
- База данных.
- Веб-интерфейс.
- Многопоточность/распределённая обработка.
- Массовый рефакторинг в многофайловую архитектуру без явной задачи.

## Environment Contract
- Python запускается через локальный venv `.venv`.
- Секреты только через env/CLI: `TG_API_ID`, `TG_API_HASH`.
- Файл сессии Telethon (`*.session`) считается чувствительным и не должен публиковаться.

## Canonical Commands
- Setup: `make install`
- Run: `make run -- --channel @channel_name`
- Run with output path: `make run -- --channel @channel_name --output export_channel_name.txt`
- Quick smoke run: `make run -- --channel @channel_name --limit 5`
- Cleanup: `make clean`

## Change Policy
- Keep changes minimal and task-focused.
- Preserve backward compatibility of CLI flags unless migration is requested.
- Do not silently change TXT schema.
- Any new flag must include:
  - argparse option
  - help text
  - mention in `tech-doc.md`
  - usage example

## Code Quality Rules
- Prefer small pure helper functions for parsing/normalization/serialization.
- Keep network/retry logic explicit and observable via stderr messages.
- Use exit codes consistently:
  - `2`: invalid credentials
  - `3`: channel/access errors
  - `4`: network/flood/retry exhausted
  - `5`: output write errors
- Avoid hidden side effects and global mutable state.

## Testing and Verification
Пока нет unit-тестов, поэтому минимум для каждой задачи:
1. Static sanity: `python3 -m py_compile tg-scraper.py`
2. CLI sanity: `make run -- --help`
3. Functional smoke (if credentials are available):
   - `make run -- --channel @<known_channel> --limit 3 --output /tmp/tg_smoke.txt`

Если в задаче меняется формат экспорта или логика полей, добавить/обновить sample output в документации.

## Documentation Policy
- `tech-doc.md` must reflect actual behavior of CLI.
- When behavior changes, update docs in the same task.
- Keep examples executable and aligned with current Make targets.

## Security and Privacy
- Never print `TG_API_HASH` in logs.
- Do not commit `.session` files or exported data with private content.
- Treat channel export files as potentially sensitive data.

## Suggested Evolution Roadmap
1. Add structured tests for pure functions (`normalize_channel`, `to_iso_z`, `extract_reactions`).
2. Split script into small package modules (`cli.py`, `exporter.py`, `formatters.py`) without changing CLI contract.
3. Add optional JSONL export while keeping TXT default.
4. Add date-range filtering flags with deterministic behavior.

## Agent Execution Checklist
Before finalizing any change:
1. Confirm CLI still runs via `make run`.
2. Confirm docs are consistent with code.
3. Confirm no secrets/session artifacts are introduced into tracked files.
4. Summarize exactly what changed and how to verify.
