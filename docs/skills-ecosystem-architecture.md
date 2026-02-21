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
│   └── webm-to-mp4-converter/
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
- `capability_contract` (`input_schema` + `output_schema`)
- `coverage_confidence` (`0..1`, для LLM-шагов)
- `coverage_rationale` (краткое обоснование выбора capability)

Шаг считается покрытым только если:

1. В реестре есть кандидат по `capability`.
2. `capability_contract` шага совместим с `input_schema/output_schema` утилиты.
3. Для LLM-шага `coverage_confidence >= порога` (fail-closed).

Иначе `tool=null` и добавляется запись в `gap-report`.

### 3.3 Контракт отчета о пробелах (gap-report)

Отчет формируется всегда, если что-то не покрыто:

- `missing_capability`
- `reason` (`no_capability_match|schema_incompatible|low_confidence|invalid_capability`)
- `reason_message`
- `reason_details`
- `proposed_tool_name`
- `proposed_input_schema`
- `proposed_output_schema`
- `priority` (`high|medium|low`)

## 4) Роли скиллов

### `request-router`

- Нормализует запрос.
- Выделяет intents и требования к входам/выходам.
- Генерирует workflow-план на уровне capability.
- Для известных направлений (YouTube, Google Drive, Yandex Disk URL, webm->mp4) строит rule-based план без LLM.
- Для `video.convert` rule-based путь поддерживает:
  - `mode=all`: все `.webm` из `input_data`
  - `mode=selected`: конкретные имена файлов `.webm`

### `workflow-executor`

- Резолвит capability -> конкретная утилита через реестр.
- Выполняет шаги по порядку/графу.
- Пробрасывает артефакты между шагами.
- Сохраняет `state/runs/<run_id>.json`.
- Пробрасывает `stderr` утилит в рантайме, поэтому прогресс long-running шагов виден в реальном времени.

Практический шорткат для «сразу обработать сообщение»:

- `make agent TEXT='...'` — автономный вход: `intent-normalizer -> hybrid planner (rule+LLM) -> gap-detector -> policy-engine -> workflow-executor`
  - В `--output pretty` показывает прогресс по фазам (планирование, gap-check, policy-check, execution/preview) и итог в формате:
    - `Задача успешно выполнена` + список выполненных операций (`step_id capability`)
    - `Задача не выполнена` + выполненные операции + недостающие операции
  - `LLM_LOG=1` печатает секции request/response по каждому LLM-вызову (с call-id, payload, raw body, extracted content и retry-событиями)
  - Логи LLM появляются только если реально сработал LLM fallback (rule path не сматчился)
- `make dispatch TEXT='...'` — `request-router (text) -> gap-detector -> workflow-executor`
- `make dispatch TEXT='...' DRY_RUN=1` — показать команды, не исполняя инструменты
- `make dispatch` — опциональный путь через capability/workflow-пайплайн; прямой режим работы агента по коду также допустим.

### `gap-detector`

- Проверяет каждый шаг плана на покрытие по цепочке:
  - capability match
  - contract compatibility gate
  - confidence gate (для LLM)
- Генерирует gap-report.
- При наличии пробелов переводит workflow в режим partial-complete.

### `policy-engine`

- Применяет allow/deny правила по capability.
- Валидирует лимиты (`max_steps`, `max_tool_retries`, `max_run_seconds`, `max_llm_calls`).
- Блокирует выполнение с `status=blocked_by_policy`, если политика нарушена.

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
2. Проверка совместимости по `capability_contract.input_schema` и `capability_contract.output_schema`.
3. Для LLM-плана: проверка `coverage_confidence` (fail-closed).
4. Выбор по приоритету и стабильности.
5. Если кандидатов нет или confidence ниже порога -> gap-report.

## 6) Пример сценария (YouTube -> Google Drive)

Запрос: «Скачай видео по ссылке X и положи в папку Y на Drive».

План:

1. `youtube.download` -> `youtube-downloader`
2. `drive.upload` -> `drive-uploader` (вход: файл из шага 1)

Если утилита для целевой capability отсутствует:

- План получает `status=partial-complete`.
- Исполнение не запускается.
- Возвращается gap-report с предложением создать недостающую утилиту.

## 7) Минимальные правила для масштабирования

- Новая утилита обязана добавлять только свою папку в `tools/` и валидный `tool.yaml`.
- Capability-имена в формате `domain.action` (`youtube.download`, `drive.upload`, `video.convert`).
- Оркестратор не знает о конкретных утилитах, знает только capabilities и контракты.
- Любой пробел должен автоматически превращаться в machine-readable gap-report.

## 8) Дорожная карта внедрения

1. Ввести `tool.yaml` для существующих утилит (`youtube-downloader`, `tg-scraper`) по общей схеме.
2. Реализовать реестр и проверку схемы. ✅
   - `make validate-manifests` — проверить `tools/*/tool.yaml` по `schemas/tool-manifest.schema.json`
   - `make registry` — собрать кэш реестра в `state/registry-cache.json`
   - `make resolve CAP=domain.action` — выбрать лучшую утилиту для capability из кэша
3. Реализовать `request-router` и `gap-detector`.
4. Добавить `workflow-executor` с логами, retry и timeout. ✅
5. Добавить автономный CLI (`scripts/agent.rb`) с policy-gate и LLM fallback. ✅
6. Добавить `tool-scaffolder` для быстрого создания недостающих утилит.
