# gap-detector

Проверяет `workflow plan` (JSON) на покрытие реестром (`state/registry-cache.json`), проставляет `tool` для покрытых шагов и формирует `gap_report` для отсутствующих capabilities.

## CLI

```bash
ruby skills/gap-detector/gap_detector.rb detect --plan plan.json --pretty
```

Опции:
- `--plan PATH` (обязательно) — путь к workflow plan JSON
- `--registry PATH` — путь к registry cache JSON (по умолчанию `state/registry-cache.json`)
- `--output PATH` — записать результат в файл (иначе stdout)
- `--pretty` — `JSON.pretty_generate`

## Выход

Обновленный workflow plan JSON:
- `steps[].tool` и `steps[].tool_meta` (если инструмент найден)
- `gap_report[]` и `status: complete|partial-complete`

