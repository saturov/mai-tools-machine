# request-router

Генерирует `workflow plan` (JSON) из входного `request` (YAML/JSON) на уровне **capability**.

## CLI

```bash
ruby skills/request-router/request_router.rb route --request templates/workflow/request.example.yaml --pretty
```

Для «живых» пользовательских сообщений (текст/чат) — извлекает ссылки и строит request автоматически:

```bash
ruby skills/request-router/request_router.rb route-text --text "Скачай https://www.youtube.com/live/VIDEO и положи в https://drive.google.com/drive/folders/FOLDER" --pretty
```

Опции:
- `--request PATH` (обязательно) — путь к request YAML/JSON
- `--output PATH` — записать результат в файл (иначе stdout)
- `--pretty` — `JSON.pretty_generate`

## Выход

JSON вида:
- `plan_id`, `request_id`, `user_goal`, `created_at`, `status`
- `steps[]`: `{ step_id, capability, tool: null, inputs, capability_contract }`
