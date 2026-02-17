# Архитектура экосистемы утилит и скиллов

## 1) Цели

- Подключать новые утилиты без переписывания оркестратора.
- Декомпозировать пользовательский запрос на шаги и исполнять их как workflow.
- Явно сигнализировать о пробелах: каких утилит не хватает для полного выполнения.
- Держать репозиторий простым: минимум дублирования, четкие контракты, валидация через схемы.

## 2) Рекомендуемая структура репозитория

```text
my-tools-sandbox/
├── tools/                         # Самостоятельные утилиты
│   ├── youtube-downloader/
│   │   ├── tool.yaml             # Манифест (контракт утилиты)
│   │   ├── run.sh                # Точка входа (или cli.py)
│   │   └── README.md             # Локальная документация утилиты (опционально)
│   └── drive-uploader/
│       ├── tool.yaml
│       └── run.sh
├── skills/
│   ├── request-router/           # Скилл: intent -> план действий
│   ├── workflow-executor/        # Скилл: выполнение плана и ретраи
│   ├── gap-detector/             # Скилл: определение недостающих утилит
│   └── tool-scaffolder/          # Скилл: генерация шаблона новой утилиты
├── schemas/
│   └── tool-manifest.schema.json # Единая схема манифеста утилиты
├── templates/
│   ├── tool/tool.yaml            # Шаблон манифеста новой утилиты
│   └── workflow/request.example.yaml
├── state/
│   ├── registry-cache.json       # Кэш индекса утилит
│   └── runs/                     # Логи выполнения workflow
└── docs/
    └── skills-ecosystem-architecture.md
```

## 3) Ключевые контракты

### 3.1 Контракт утилиты (tool manifest)

Каждая утилита обязана иметь `tool.yaml`. Он описывает:

- `name`, `version`, `description`
- `capabilities`: список атомарных возможностей (например `youtube.download`, `drive.upload`)
- `input_schema`: обязательные входные поля
- `output_schema`: формат результата
- `entrypoint`: как запускать утилиту
- `dependencies`: внешние сервисы (YouTube, Google Drive и т.п.)
- `idempotency`: безопасен ли повторный запуск

Это позволяет оркестратору выбирать утилиты декларативно, а не по hardcode-правилам.

### 3.2 Контракт плана выполнения (workflow plan)

План формируется как DAG/последовательность шагов:

- `step_id`
- `capability`
- `tool` (или `null`, если отсутствует)
- `inputs` (мэппинг из параметров запроса и выходов предыдущих шагов)
- `on_failure` (retry/skip/fail)

Если для шага нет подходящей утилиты, `tool=null` и добавляется запись в `gap-report`.

### 3.3 Контракт отчета о пробелах (gap-report)

Отчет формируется всегда, если что-то не покрыто:

- `missing_capability`
- `reason`
- `proposed_tool_name`
- `proposed_input_schema`
- `proposed_output_schema`
- `priority` (`high|medium|low`)

## 4) Роли скиллов

### `request-router`

- Нормализует запрос.
- Выделяет intents и требования к входам/выходам.
- Генерирует workflow-план на уровне capability.

### `workflow-executor`

- Резолвит capability -> конкретная утилита через реестр.
- Выполняет шаги по порядку/графу.
- Пробрасывает артефакты между шагами.
- Сохраняет `state/runs/<run_id>.json`.

### `gap-detector`

- Проверяет каждый шаг плана на покрытие.
- Генерирует gap-report.
- При наличии пробелов переводит workflow в режим partial-complete.

### `tool-scaffolder`

- Создает каркас новой утилиты из `templates/tool/`.
- Проставляет манифест и заготовки entrypoint.
- Запускает валидацию схемы.

## 5) Реестр утилит

Реестр строится автоматически сканированием `tools/*/tool.yaml`.

Индекс хранит:

- `capability -> [tool candidates]`
- версии
- приоритет выбора
- признак готовности (`stable|experimental`)

Базовый алгоритм выбора:

1. Фильтр по нужной capability.
2. Проверка совместимости по `input_schema`.
3. Выбор по приоритету и стабильности.
4. Если кандидатов нет -> gap-report.

## 6) Пример сценария (YouTube -> Google Drive)

Запрос: «Скачай видео по ссылке X и положи в папку Y на Drive».

План:

1. `youtube.download` -> `youtube-downloader`
2. `drive.upload` -> `drive-uploader` (вход: файл из шага 1)

Если `drive-uploader` отсутствует:

- Шаг 1 выполняется.
- Шаг 2 помечается как missing.
- Возвращается gap-report с предложением создать утилиту `drive-uploader`.

## 7) Минимальные правила для масштабирования

- Новая утилита обязана добавлять только свою папку в `tools/` и валидный `tool.yaml`.
- Capability-имена в формате `domain.action` (`youtube.download`, `drive.upload`).
- Оркестратор не знает о конкретных утилитах, знает только capabilities и контракты.
- Любой пробел должен автоматически превращаться в machine-readable gap-report.

## 8) Дорожная карта внедрения

1. Ввести `tool.yaml` для существующих утилит (`youtube-downloader`, `tg-scraper`) по общей схеме.
2. Реализовать реестр и проверку схемы.
3. Реализовать `request-router` и `gap-detector`.
4. Добавить `workflow-executor` с логами и retry.
5. Добавить `tool-scaffolder` для быстрого создания недостающих утилит.
