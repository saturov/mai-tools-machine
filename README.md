# mAI-tools-machine

Накапливайте инструменты, объединяйте их в цепочки и запускайте целые флоу простым запросом на естественном языке.

## Быстрый старт

1) Склонируйте репозиторий и перейдите в папку проекта.
2) Установите зависимости для запуска диспетчера: Ruby (для `make`-скриптов).
3) Сконфигурируйте LLM (см. ниже).
4) Агент готов к работе.

Примечание: зависимости утилит ставятся при первом запуске конкретной утилиты.

## Пример работы

```bash
make agent TEXT='Скачай видео с ютуба {URL_1} и загрузи его в папку на Google Drive {URL_2}'
```

Ожидаемый результат: видео скачано с YouTube и загружено в указанную папку на Google Drive.

Ещё пример:

```bash
make agent TEXT='Сконвертируй все webm из input_data в mp4'
```

Ожидаемый результат: все `.webm` из `input_data` конвертированы в `.mp4` и сохранены в `output_data`.

## Конфигурация LLM

1) Скопируйте пример в рабочий конфиг:

```bash
cp config/agent.yaml.example config/agent.yaml
```

2) Отредактируйте `config/agent.yaml`:
- `provider`: обычно `openai_compatible`
- `model`: имя модели
- `base_url`: базовый URL API
- `api_key`: ключ доступа

## Реализованные утилиты

- `youtube-downloader` — скачивает видео YouTube в MP4 с целевым качеством:
  - `target_quality` берется из запроса агента; если не указан, используется `720p`;
  - в `strict` режиме сначала ищется exact quality (например `1080p`), затем fallback на лучший доступный `<= target`;
  - использует retry-цепочку с cookies браузера (`chrome` -> `safari` -> `firefox`) для кейсов с ограничениями доступа;
  - в результате шага доступны `target_quality`, `actual_quality`, `fallback`.
- `drive-uploader` — загружает локальный файл в папку Google Drive.
- `webm-to-mp4-converter` — конвертирует один или несколько `.webm` в `.mp4` (`input_data` -> `output_data`).

### Переменные окружения для `youtube-downloader`

- `YT_COOKIES_FROM_BROWSER` — браузер для импорта cookies (по умолчанию `chrome`).
- `YT_TARGET_QUALITY` — желаемая высота видео (по умолчанию `720`).
- `YT_MIN_HEIGHT` — legacy alias для `YT_TARGET_QUALITY`.
- `YT_QUALITY_POLICY` — `strict` или `best_effort` (по умолчанию `strict`).
- `YT_PO_TOKEN_ANDROID` — PO token для Android-клиента YouTube (опционально).
- `YT_PO_TOKEN_IOS` — PO token для iOS-клиента YouTube (опционально).

## Как добавить свою утилиту

1) Создайте утилиту в директории `tools/<your-tool>/`. Каждая утилита должна содержать файлы:
- `tool.yaml` (описание, capability, схемы входа/выхода)
- `run.sh` (точка входа)
2) При необходимости добавьте зависимости в `requirements.txt` внутри вашей утилиты.
3) Проверьте и обновите реестр:

```bash
make validate-manifests
make registry
```

## Статус

Репозиторий в активной разработке. Всё может резко и сильно меняться.
