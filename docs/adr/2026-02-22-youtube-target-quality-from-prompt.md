# ADR-2026-02-22: Контракт качества YouTube из prompt (`target_quality` -> `actual_quality`)

## Статус
Принято (2026-02-22)

## Контекст
Предыдущее поведение `youtube.download` было ориентировано на фиксированный профиль до `720p` и не поддерживало явный выбор качества из пользовательского prompt. Это не закрывало сценарий `в качестве 1080` и не давало стабильного контракта "что запросили vs что получили" в терминальном выводе.

## Решение
1. В `request-router` добавлен извлекатель `target_quality` из текста:
   - поддерживаемые паттерны: `в качестве N`, `качество N`, `Np`;
   - если не найдено, используется дефолт `720`.
2. Шаг `youtube.download` получает вход `target_quality` как часть plan inputs.
3. В `youtube-downloader` реализована стратегия выбора формата:
   - `strict`: сначала exact target (`height=N`), затем fallback на лучший `height<=N`;
   - `best_effort`: сразу лучший `height<=N`.
4. Результат `youtube-downloader` возвращается в JSON с полями:
   - `file_path`
   - `target_quality`
   - `actual_quality`
   - `fallback`
   - `fallback_reason`
5. В status-события workflow пробрасываются `target_quality`, `actual_quality`, `quality_fallback`, чтобы это было видно в стандартном терминальном выводе.

## Рассмотренные альтернативы
1. Сохранять только `min_height` без explicit `target_quality`.
   - Отклонено: не соответствует требованию exact-target приоритета и неочевидно для пользователя.
2. Печатать requested/actual только в raw stderr утилиты.
   - Отклонено: нет стабильного контракта в стандартных stage-строках агента.

## Последствия
Плюсы:
- Пользователь может управлять качеством прямо в prompt.
- Есть прозрачная диагностика `requested vs actual` и явный fallback.
- Сохранена retry-цепочка cookies без логирования секретов.

Минусы:
- В `strict` режиме может быть больше попыток (exact + fallback phase).
- Логи шага стали подробнее.

## Затронутые файлы
- `skills/request-router/request_router.rb`
- `skills/workflow-executor/workflow_executor.rb`
- `scripts/agent.rb`
- `tools/youtube-downloader/youtube_downloader.py`
- `tools/youtube-downloader/tool.yaml`
- `tools/youtube-downloader/run.sh`
- `scripts/request_router_test.rb`
- `scripts/workflow_executor_test.rb`
- `scripts/agent_test.rb`
- `tools/youtube-downloader/tests/test_quality_policy.py`
- `README.md`
- `docs/skills-ecosystem-architecture.md`
