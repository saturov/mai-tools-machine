# ADR-2026-02-23: Архитектура логгирования агента (status + LLM trace)

## Статус
Принято (2026-02-23)

## Контекст
Логгирование в проекте фрагментировано:
- терминальный статус агента (pretty/TTY redraw) был встроен в `scripts/agent.rb`;
- LLM trace-вывод был встроен в `scripts/llm_client.rb`;
- в других CLI-скриптах используются отдельные `puts/print/warn`.

Такая структура усложняет поддержку, изоляцию тестов и развитие контракта логгирования.

## Решение
1. Вынести логгирование `agent + llm core` в отдельный модуль `scripts/logging/`:
   - `scripts/logging/agent_status.rb`
   - `scripts/logging/llm_trace_logger.rb`
2. Зафиксировать контракт рендера статуса:
   - `start(stages:, chain:)`
   - `update_stage(name:, state:)`
   - `update_chain(steps:, step_states:)`
   - `emit_coverage_error(missing_caps:)`
   - `emit_final(success:, message: nil)`
   - `flush`
3. Зафиксировать фабрику `AgentLogging::Status.build_renderer(output_format:, io:, no_color_env:)` с выбором:
   - `NullRenderer` для non-pretty;
   - `PlainRenderer` для pretty non-TTY/NO_COLOR;
   - `TTYRenderer` для pretty TTY с ANSI redraw.
4. Зафиксировать LLM trace-логгер `AgentLogging::LLMTraceLogger` с интерфейсом:
   - `request(call_id:, endpoint:, model:, payload:)`
   - `response(call_id:, http_status:, raw_body:)`
   - `content(call_id:, extracted_content:)`
   - `retry(call_id:, next_attempt:, reason:)`
5. Обновить `LLMClient::Client`:
   - добавить `logger:` в `initialize`/`from_settings`;
   - сохранить back-compat `log_io:` (если `logger` не передан, строится `LLMTraceLogger` из `log_io`).

## Совместимость
Внешний pretty-контракт сохранен без изменений:
- те же строки и emoji;
- тот же порядок этапов;
- тот же TTY redraw-подход.

## Тестирование и покрытие
1. Для `scripts/logging/**/*.rb` введен отдельный запуск тестов с `SimpleCov`.
2. Включено branch coverage.
3. Порог: 100% line и 100% branch, включая per-file threshold.
4. Единая точка запуска: `scripts/logging/logging_suite_test.rb`.

## Границы решения
- Решение покрывает только `agent + llm core`.
- Унификация вывода остальных CLI (`dispatch`, `tool_registry`, `skills/*`) находится вне текущего scope.

## Последствия
Плюсы:
- Изолированный и переиспользуемый logging-слой.
- Жесткий coverage-gate для критичного статуса и LLM trace.
- Упрощение `scripts/agent.rb` и `scripts/llm_client.rb`.

Минусы:
- Появилась зависимость тестового контура от `SimpleCov`/`Bundler`.

## Добавление новых утилит
- Шаблон PRD для проектирования задачи: `schemas/prd-task-template.md`.

## Затронутые файлы
- `scripts/agent.rb`
- `scripts/llm_client.rb`
- `scripts/logging/agent_status.rb`
- `scripts/logging/llm_trace_logger.rb`
- `scripts/logging/test_helper.rb`
- `scripts/logging/agent_status_test.rb`
- `scripts/logging/llm_trace_logger_test.rb`
- `scripts/logging/logging_suite_test.rb`
- `Makefile`
- `Gemfile`
- `schemas/prd-task-template.md`
