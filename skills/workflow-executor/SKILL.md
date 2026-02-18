# workflow-executor

Выполняет `workflow plan` (JSON) по шагам: резолвит входы (`inputs.*.from`) из `request` и выходов предыдущих шагов, запускает инструменты из реестра и собирает `run`-артефакт.

## CLI

> Требует `state/registry-cache.json` (соберите через `make registry`).

```bash
ruby skills/workflow-executor/workflow_executor.rb run --plan plan.json --request request.yaml --pretty
```

Сухой прогон (печатает команды и placeholder-значения, ничего не запускает):

```bash
ruby skills/workflow-executor/workflow_executor.rb run --plan plan.json --request request.yaml --dry-run --pretty
```

Опции:
- `--plan PATH` (обязательно) — путь к workflow plan JSON (желательно после `gap-detector`)
- `--request PATH` (обязательно) — путь к request YAML/JSON
- `--registry PATH` — путь к registry cache JSON (по умолчанию `state/registry-cache.json`)
- `--runs-dir PATH` — куда писать run-артефакты (по умолчанию `state/runs`)
- `--dry-run` — не исполнять шаги, только показать что будет выполнено
- `--output PATH` — записать результат в файл (иначе stdout)
- `--pretty` — `JSON.pretty_generate`

