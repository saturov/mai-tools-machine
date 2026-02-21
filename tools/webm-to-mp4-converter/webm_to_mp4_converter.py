#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ConversionTask:
    index: int
    input_name: str
    input_path: Path
    output_path: Path
    duration_seconds: float
    source_size_bytes: int


class ProgressTracker:
    def __init__(self, tasks: list[ConversionTask]) -> None:
        self._lock = threading.Lock()
        self._total = len(tasks)
        self._order = {task.input_name: task.index for task in tasks}
        self._weights = {
            task.input_name: (task.duration_seconds if task.duration_seconds > 0 else 1.0)
            for task in tasks
        }
        self._total_weight = sum(self._weights.values()) if self._weights else 1.0
        self._fractions = {task.input_name: 0.0 for task in tasks}
        self._last_pct = {task.input_name: -1.0 for task in tasks}

    def update(self, input_name: str, fraction: float, *, force: bool = False) -> None:
        with self._lock:
            clamped = max(0.0, min(1.0, fraction))
            if clamped < self._fractions.get(input_name, 0.0):
                return

            old = self._fractions.get(input_name, 0.0)
            self._fractions[input_name] = clamped
            pct = clamped * 100.0
            last_pct = self._last_pct.get(input_name, -1.0)
            should_emit = force or pct >= 100.0 or (pct - last_pct) >= 2.0
            if not should_emit and old == clamped:
                return

            if should_emit:
                self._last_pct[input_name] = pct
                idx = self._order.get(input_name, 0)
                overall = self._overall_percent()
                self._emit(f"[{idx}/{self._total}] {input_name}: {pct:5.1f}% | overall {overall:5.1f}%")

    def finish(self, input_name: str, *, ok: bool, error: str | None = None) -> None:
        self.update(input_name, 1.0, force=True)
        with self._lock:
            idx = self._order.get(input_name, 0)
            overall = self._overall_percent()
            if ok:
                self._emit(f"[{idx}/{self._total}] {input_name}: done | overall {overall:5.1f}%")
            else:
                details = f" ({error})" if error else ""
                self._emit(f"[{idx}/{self._total}] {input_name}: failed{details} | overall {overall:5.1f}%")

    def _overall_percent(self) -> float:
        weighted = 0.0
        for name, fraction in self._fractions.items():
            weighted += fraction * self._weights.get(name, 1.0)
        return 100.0 * (weighted / self._total_weight)

    @staticmethod
    def _emit(message: str) -> None:
        print(message, file=sys.stderr, flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert .webm videos from input_data to output_data as .mp4"
    )
    parser.add_argument("--mode", choices=["all", "selected"], required=True)
    parser.add_argument("--file", action="append", default=[], help="Input .webm file name (repeat for multiple files)")
    parser.add_argument("--input-dir", default="input_data")
    parser.add_argument("--output-dir", default="output_data")
    parser.add_argument("--jobs", type=int, default=0, help="Parallel conversion jobs; 0 means auto")
    parser.add_argument("--overwrite", dest="overwrite", action="store_true", default=True)
    parser.add_argument("--no-overwrite", dest="overwrite", action="store_false")
    return parser.parse_args(argv)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def resolve_dir(raw: str) -> Path:
    candidate = Path(raw).expanduser()
    if candidate.is_absolute():
        return candidate
    return (repo_root() / candidate).resolve()


def dedupe_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def probe_duration_seconds(file_path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(file_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return 0.0
    try:
        value = float(result.stdout.strip())
    except ValueError:
        return 0.0
    return value if value > 0 else 0.0


def parse_out_time_to_seconds(value: str) -> float | None:
    try:
        hours_str, minutes_str, seconds_str = value.strip().split(":")
        return int(hours_str) * 3600 + int(minutes_str) * 60 + float(seconds_str)
    except Exception:
        return None


def convert_one(task: ConversionTask, *, overwrite: bool, tracker: ProgressTracker) -> dict[str, Any]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y" if overwrite else "-n",
        "-i",
        str(task.input_path),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "24",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        "-progress",
        "pipe:1",
        str(task.output_path),
    ]

    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    assert process.stdout is not None
    assert process.stderr is not None

    for raw_line in process.stdout:
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "out_time_ms":
            try:
                current_seconds = int(value) / 1_000_000.0
            except ValueError:
                continue
            if task.duration_seconds > 0:
                tracker.update(task.input_name, current_seconds / task.duration_seconds)
        elif key == "out_time":
            current_seconds = parse_out_time_to_seconds(value)
            if current_seconds is not None and task.duration_seconds > 0:
                tracker.update(task.input_name, current_seconds / task.duration_seconds)
        elif key == "progress" and value == "end":
            tracker.update(task.input_name, 1.0, force=True)

    stderr_output = process.stderr.read().strip()
    return_code = process.wait()
    if return_code != 0:
        error_line = stderr_output.splitlines()[-1] if stderr_output else f"ffmpeg exited with code {return_code}"
        return {
            "input_file": task.input_name,
            "output_file": str(task.output_path),
            "status": "error",
            "error": error_line,
        }

    if not task.output_path.exists():
        return {
            "input_file": task.input_name,
            "output_file": str(task.output_path),
            "status": "error",
            "error": "ffmpeg finished successfully but output file is missing",
        }

    return {
        "input_file": task.input_name,
        "output_file": str(task.output_path),
        "status": "ok",
        "source_size_bytes": task.source_size_bytes,
        "output_size_bytes": task.output_path.stat().st_size,
    }


def collect_tasks(
    *,
    mode: str,
    selected_files: list[str],
    input_dir: Path,
    output_dir: Path,
) -> tuple[list[ConversionTask], list[dict[str, Any]], list[str]]:
    tasks: list[ConversionTask] = []
    prebuilt_results: list[dict[str, Any]] = []
    ordered_names: list[str] = []

    if mode == "all":
        names = sorted(
            [entry.name for entry in input_dir.iterdir() if entry.is_file() and entry.suffix.lower() == ".webm"]
        )
    else:
        names = dedupe_preserve_order([Path(raw).name.strip() for raw in selected_files if raw.strip()])

    for name in names:
        ordered_names.append(name)
        if not name.lower().endswith(".webm"):
            prebuilt_results.append(
                {
                    "input_file": name,
                    "output_file": str((output_dir / Path(name).with_suffix(".mp4").name)),
                    "status": "error",
                    "error": "only .webm file names are allowed",
                }
            )
            continue

        input_path = input_dir / name
        output_path = output_dir / Path(name).with_suffix(".mp4").name

        if not input_path.exists() or not input_path.is_file():
            prebuilt_results.append(
                {
                    "input_file": name,
                    "output_file": str(output_path),
                    "status": "error",
                    "error": "input file not found",
                }
            )
            continue

        duration = probe_duration_seconds(input_path)
        size_bytes = input_path.stat().st_size
        tasks.append(
            ConversionTask(
                index=len(tasks) + 1,
                input_name=name,
                input_path=input_path,
                output_path=output_path,
                duration_seconds=duration,
                source_size_bytes=size_bytes,
            )
        )

    return tasks, prebuilt_results, ordered_names


def auto_jobs() -> int:
    cpu = os.cpu_count() or 2
    return max(1, math.ceil(cpu / 2))


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.mode == "selected" and not args.file:
        print("mode=selected requires at least one --file", file=sys.stderr)
        return 1

    input_dir = resolve_dir(args.input_dir)
    output_dir = resolve_dir(args.output_dir)

    if not input_dir.exists() or not input_dir.is_dir():
        print(f"Input directory not found: {input_dir}", file=sys.stderr)
        payload = {
            "converted_count": 0,
            "failed_count": 1,
            "output_files": [],
            "results": [
                {
                    "input_file": "*",
                    "status": "error",
                    "error": "input directory not found",
                }
            ],
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)

    tasks, prebuilt_results, ordered_names = collect_tasks(
        mode=args.mode,
        selected_files=args.file,
        input_dir=input_dir,
        output_dir=output_dir,
    )

    for idx, task in enumerate(tasks, start=1):
        tasks[idx - 1] = ConversionTask(
            index=idx,
            input_name=task.input_name,
            input_path=task.input_path,
            output_path=task.output_path,
            duration_seconds=task.duration_seconds,
            source_size_bytes=task.source_size_bytes,
        )

    tracker = ProgressTracker(tasks)
    result_map: dict[str, dict[str, Any]] = {entry["input_file"]: entry for entry in prebuilt_results}

    if tasks:
        max_workers = min(len(tasks), (args.jobs if args.jobs and args.jobs > 0 else auto_jobs()))
        print(
            f"Converting {len(tasks)} file(s) with {max_workers} parallel job(s) from {input_dir} to {output_dir}",
            file=sys.stderr,
            flush=True,
        )

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(convert_one, task, overwrite=args.overwrite, tracker=tracker): task
                for task in tasks
            }
            for future in concurrent.futures.as_completed(futures):
                task = futures[future]
                try:
                    result = future.result()
                except Exception as exc:  # safeguard to continue other files
                    result = {
                        "input_file": task.input_name,
                        "output_file": str(task.output_path),
                        "status": "error",
                        "error": str(exc),
                    }

                result_map[task.input_name] = result
                tracker.finish(task.input_name, ok=result.get("status") == "ok", error=result.get("error"))
    else:
        print("No matching .webm files found for conversion.", file=sys.stderr, flush=True)

    if not ordered_names:
        ordered_names = [entry["input_file"] for entry in prebuilt_results]

    ordered_results = [result_map[name] for name in ordered_names if name in result_map]
    converted = [entry for entry in ordered_results if entry.get("status") == "ok"]
    failed = [entry for entry in ordered_results if entry.get("status") != "ok"]

    payload = {
        "converted_count": len(converted),
        "failed_count": len(failed),
        "output_files": [entry["output_file"] for entry in converted if isinstance(entry.get("output_file"), str)],
        "results": ordered_results,
    }
    print(json.dumps(payload, ensure_ascii=False))

    return 0 if converted else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
