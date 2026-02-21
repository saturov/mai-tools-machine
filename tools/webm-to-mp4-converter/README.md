# webm-to-mp4-converter

Конвертирует `.webm` видео из `input_data` в `.mp4` в `output_data`.

- Поддерживает пакетную обработку.
- Показывает прогресс по каждому файлу и общий прогресс в `stderr`.
- Печатает итоговый JSON в `stdout`.

## Примеры

Конвертировать все `.webm` из `input_data`:

```bash
./run.sh --mode all --input-dir input_data --output-dir output_data
```

Конвертировать конкретные файлы:

```bash
./run.sh --mode selected --file one.webm --file two.webm --input-dir input_data --output-dir output_data
```

Ограничить число параллельных задач:

```bash
./run.sh --mode all --jobs 2 --input-dir input_data --output-dir output_data
```

## Формат результата (stdout)

```json
{
  "converted_count": 2,
  "failed_count": 0,
  "output_files": ["/abs/path/output_data/one.mp4"],
  "results": [
    {
      "input_file": "one.webm",
      "output_file": "/abs/path/output_data/one.mp4",
      "status": "ok",
      "source_size_bytes": 123,
      "output_size_bytes": 124
    }
  ]
}
```
