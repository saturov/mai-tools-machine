#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

try:
    import yt_dlp
    from yt_dlp.utils import DownloadError
except ModuleNotFoundError:  # pragma: no cover - exercised in unit tests without deps
    yt_dlp = None

    class DownloadError(Exception):
        pass


DEFAULT_TARGET_QUALITY = 720
MIN_TARGET_QUALITY = 144
MAX_TARGET_QUALITY = 4320
DEFAULT_QUALITY_POLICY = "strict"
DEFAULT_COOKIES_BROWSER = "chrome"
COOKIE_BROWSER_FALLBACKS = ["safari", "firefox"]


@dataclass
class DownloadOutcome:
    path: Path
    client: str
    auth_context: str
    height: int | None
    format_id: str | None
    target_quality: int
    quality_policy: str
    fallback: bool = False
    fallback_reason: str | None = None


class SilentLogger:
    def __init__(self) -> None:
        self.warnings: list[str] = []
        self.errors: list[str] = []

    def debug(self, msg: str) -> None:
        _ = msg

    def warning(self, msg: str) -> None:
        self.warnings.append(msg)

    def error(self, msg: str) -> None:
        self.errors.append(msg)


def clean_error_message(message: str) -> str:
    msg = message.strip()
    if msg.startswith("ERROR:"):
        return msg[6:].strip()
    return msg


def is_retryable_download_error(message: str) -> bool:
    lower = message.lower()
    retryable_markers = (
        "requested format is not available",
        "only images are available",
        "challenge solving failed",
        "this video is drm protected",
        "no video formats found",
        "http error 403",
        "cookiesfrombrowser",
        "cookie",
    )
    return any(marker in lower for marker in retryable_markers)


def parse_target_quality(value: str | None, *, label: str = "target quality") -> int:
    if value is None or not value.strip():
        return DEFAULT_TARGET_QUALITY
    try:
        parsed = int(value)
    except ValueError as exc:
        raise SystemExit(f"Invalid {label}={value!r}: expected integer.") from exc
    if parsed < MIN_TARGET_QUALITY:
        raise SystemExit(
            f"{label} must be >= {MIN_TARGET_QUALITY}."
        )
    if parsed > MAX_TARGET_QUALITY:
        raise SystemExit(f"{label} cannot be greater than {MAX_TARGET_QUALITY}.")
    return parsed


def normalize_target_quality(value: int, *, label: str = "target quality") -> int:
    if value < MIN_TARGET_QUALITY:
        raise SystemExit(f"{label} must be >= {MIN_TARGET_QUALITY}.")
    if value > MAX_TARGET_QUALITY:
        raise SystemExit(f"{label} cannot be greater than {MAX_TARGET_QUALITY}.")
    return value


def parse_min_height(value: str | None) -> int:
    # Backward-compatible alias for older environment variable names.
    return parse_target_quality(value, label="YT_MIN_HEIGHT")


def normalize_min_height(value: int) -> int:
    # Backward-compatible alias for legacy CLI option.
    return normalize_target_quality(value, label="min-height")


def resolve_effective_cookies_browser(cli_value: str | None) -> str | None:
    if cli_value is not None and cli_value.strip():
        raw = cli_value.strip()
    else:
        env_value = os.getenv("YT_COOKIES_FROM_BROWSER")
        raw = env_value.strip() if env_value and env_value.strip() else DEFAULT_COOKIES_BROWSER
    if raw.lower() in {"none", "off", "false"}:
        return None
    return raw


def resolve_effective_cookies_browsers(cli_value: str | None) -> list[str]:
    browser = resolve_effective_cookies_browser(cli_value)
    if browser is None:
        return []
    base = [browser]
    if cli_value is not None and cli_value.strip():
        return base
    for candidate in COOKIE_BROWSER_FALLBACKS:
        if candidate not in base:
            base.append(candidate)
    return base


def resolve_quality_policy(cli_value: str | None) -> str:
    raw = cli_value or os.getenv("YT_QUALITY_POLICY") or DEFAULT_QUALITY_POLICY
    value = raw.strip().lower()
    if value not in {"strict", "best_effort"}:
        raise SystemExit("quality policy must be strict or best_effort")
    return value


def resolve_target_quality(cli_value: int | None, min_height: int | None) -> int:
    if cli_value is not None:
        return normalize_target_quality(cli_value, label="target-quality")
    if min_height is not None:
        return normalize_min_height(min_height)
    env_target = os.getenv("YT_TARGET_QUALITY")
    if env_target and env_target.strip():
        return parse_target_quality(env_target, label="YT_TARGET_QUALITY")
    return parse_min_height(os.getenv("YT_MIN_HEIGHT"))


def resolve_effective_clients(player_clients: list[str] | None) -> list[str | None]:
    if not player_clients:
        return [None]
    cleaned = [client.strip() for client in player_clients if isinstance(client, str) and client.strip()]
    if not cleaned:
        raise SystemExit("player clients list cannot be empty")
    return cleaned


def client_label(client: str | None) -> str:
    return client if client else "auto"


def build_exact_format_selector(target_quality: int) -> str:
    return f"bestvideo[height={target_quality}]+bestaudio/best[height={target_quality}]"


def build_best_below_or_equal_selector(target_quality: int) -> str:
    return (
        f"bestvideo[height<={target_quality}]+bestaudio/"
        f"best[height<={target_quality}]"
    )


def build_format_selector(min_height: int, quality_policy: str) -> str:
    # Backward-compatible helper used by tests.
    target_quality = normalize_min_height(min_height)
    if quality_policy == "strict":
        return build_exact_format_selector(target_quality)
    return build_best_below_or_equal_selector(target_quality)


def build_attempt_plan(
    clients: list[str | None], cookie_browsers: list[str]
) -> list[tuple[str | None, str, str | None]]:
    attempts: list[tuple[str | None, str, str | None]] = []
    for client in clients:
        attempts.append((client, "none", None))
    for browser in cookie_browsers:
        for client in clients:
            attempts.append((client, f"cookies:{browser}", browser))
    return attempts


def emit_status(message: str) -> None:
    print(f"[youtube-downloader] {message}", file=sys.stderr)


def is_quality_acceptable(height: int | None, min_height: int, quality_policy: str) -> bool:
    target_quality = normalize_min_height(min_height)
    if height is None:
        return quality_policy == "best_effort"
    if quality_policy == "strict":
        return height == target_quality
    return height <= target_quality


def extract_selected_height(info: dict) -> int | None:
    value = info.get("height")
    if isinstance(value, int) and value > 0:
        return value

    requested_formats = info.get("requested_formats")
    if isinstance(requested_formats, list):
        heights = []
        for fmt in requested_formats:
            if isinstance(fmt, dict):
                h = fmt.get("height")
                if isinstance(h, int) and h > 0:
                    heights.append(h)
        if heights:
            return max(heights)

    requested_downloads = info.get("requested_downloads")
    if isinstance(requested_downloads, list):
        heights = []
        for item in requested_downloads:
            if not isinstance(item, dict):
                continue
            h = item.get("height")
            if isinstance(h, int) and h > 0:
                heights.append(h)
                continue
            fmt = item.get("info_dict")
            if isinstance(fmt, dict):
                nested_h = fmt.get("height")
                if isinstance(nested_h, int) and nested_h > 0:
                    heights.append(nested_h)
        if heights:
            return max(heights)
    return None


def extract_selected_format_id(info: dict) -> str | None:
    format_id = info.get("format_id")
    if isinstance(format_id, str) and format_id.strip():
        return format_id

    requested_formats = info.get("requested_formats")
    if isinstance(requested_formats, list):
        ids = []
        for fmt in requested_formats:
            if isinstance(fmt, dict):
                value = fmt.get("format_id")
                if isinstance(value, str) and value.strip():
                    ids.append(value)
        if ids:
            return "+".join(ids)

    requested_downloads = info.get("requested_downloads")
    if isinstance(requested_downloads, list):
        for item in requested_downloads:
            if not isinstance(item, dict):
                continue
            value = item.get("format_id")
            if isinstance(value, str) and value.strip():
                return value
            fmt = item.get("info_dict")
            if isinstance(fmt, dict):
                nested_value = fmt.get("format_id")
                if isinstance(nested_value, str) and nested_value.strip():
                    return nested_value
    return None


def probe_height_with_ffprobe(path: Path) -> int | None:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=height",
        "-of",
        "csv=p=0",
        str(path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    value = proc.stdout.strip()
    try:
        parsed = int(value)
    except ValueError:
        return None
    return parsed if parsed > 0 else None


def resolve_downloaded_file_path(
    info: dict, ydl: yt_dlp.YoutubeDL, output_dir: Path, known_paths_before: set[Path]
) -> Path:
    candidates: list[Path] = []

    for key in ("_filename", "filepath"):
        value = info.get(key)
        if isinstance(value, str) and value.strip():
            candidates.append(Path(value))

    requested_downloads = info.get("requested_downloads")
    if isinstance(requested_downloads, list):
        for item in requested_downloads:
            if not isinstance(item, dict):
                continue
            value = item.get("filepath")
            if isinstance(value, str) and value.strip():
                candidates.append(Path(value))

    try:
        prepared = ydl.prepare_filename(info)
        if isinstance(prepared, str) and prepared.strip():
            candidates.append(Path(prepared))
    except Exception:
        pass

    for candidate in candidates:
        resolved = candidate if candidate.is_absolute() else (Path.cwd() / candidate)
        if resolved.exists():
            return resolved.resolve()
        if resolved.with_suffix(".mp4").exists():
            return resolved.with_suffix(".mp4").resolve()

    created_files = []
    for entry in output_dir.glob("*"):
        resolved = entry.resolve()
        if resolved in known_paths_before:
            continue
        if entry.is_file():
            created_files.append(entry)

    if created_files:
        newest = max(created_files, key=lambda p: p.stat().st_mtime)
        return newest.resolve()

    raise SystemExit("Download finished but saved file path could not be determined.")


def remove_file_if_exists(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except TypeError:
        if path.exists():
            path.unlink()


def normalize_youtube_url(url: str) -> str:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path_parts = [part for part in parsed.path.split("/") if part]

    if "youtube.com" in host and len(path_parts) >= 2 and path_parts[0] == "live":
        video_id = path_parts[1]
        return f"https://www.youtube.com/watch?v={video_id}"
    return url


def download_youtube_mp4_720p(
    url: str,
    cookies_from_browser: str | None = None,
    target_quality: int | None = None,
    min_height: int | None = None,
    quality_policy: str | None = None,
    player_clients: list[str] | None = None,
    po_token_android: str | None = None,
    po_token_ios: str | None = None,
    allow_strict_relaxation: bool = True,
) -> DownloadOutcome:
    if yt_dlp is None:
        raise SystemExit("yt-dlp is required. Install dependencies with: pip install -r requirements.txt")

    normalized_url = normalize_youtube_url(url)
    script_dir = Path(__file__).resolve().parent
    output_dir = script_dir / "out"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(output_dir / "%(title)s.%(ext)s")

    effective_cookies_browsers = resolve_effective_cookies_browsers(cookies_from_browser)
    effective_quality_policy = resolve_quality_policy(quality_policy)
    effective_target_quality = resolve_target_quality(target_quality, min_height)

    effective_clients = resolve_effective_clients(player_clients)
    quality_modes: list[tuple[str, str, bool]] = []
    if effective_quality_policy == "strict":
        quality_modes.append(
            (
                "exact_target",
                build_exact_format_selector(effective_target_quality),
                True,
            )
        )
    quality_modes.append(
        (
            "best_below_or_equal_target",
            build_best_below_or_equal_selector(effective_target_quality),
            False,
        )
    )
    cookies_state = (
        ",".join(effective_cookies_browsers) if effective_cookies_browsers else "disabled"
    )
    format_chain = "|".join(mode[1] for mode in quality_modes)
    emit_status(
        "strategy="
        f"{effective_quality_policy}, target_quality={effective_target_quality}, "
        f"cookies={cookies_state}, "
        f"clients={','.join(client_label(client) for client in effective_clients)}, "
        f"format={format_chain}"
    )

    def build_ydl_opts(
        format_selector: str,
        client: str | None,
        browser: str | None,
        logger: SilentLogger,
    ) -> dict:
        ydl_opts = {
            "format": format_selector,
            "outtmpl": output_template,
            "merge_output_format": "mp4",
            "noplaylist": True,
            "restrictfilenames": True,
            "quiet": True,
            "no_warnings": True,
            "noprogress": True,
            "logger": logger,
            "retries": 3,
            "fragment_retries": 3,
        }
        youtube_args: dict[str, list[str]] = {}
        if client:
            youtube_args["player_client"] = [client]
        if po_token_android:
            youtube_args["po_token"] = [
                f"android.gvs+{po_token_android}"
            ]
        if po_token_ios:
            youtube_args.setdefault("po_token", []).append(f"ios.gvs+{po_token_ios}")
        if youtube_args:
            ydl_opts["extractor_args"] = {"youtube": youtube_args}
        if browser:
            ydl_opts["cookiesfrombrowser"] = (browser,)
        return ydl_opts

    attempts = build_attempt_plan(effective_clients, effective_cookies_browsers)

    attempt_reasons: list[str] = []
    last_error: DownloadError | None = None
    for mode_index, (mode_name, format_selector, requires_exact_match) in enumerate(
        quality_modes, start=1
    ):
        emit_status(
            f"quality_mode={mode_index}/{len(quality_modes)}, "
            f"name={mode_name}, format={format_selector}"
        )
        for attempt_index, (client, auth_context, browser) in enumerate(attempts, start=1):
            current_client = client_label(client)
            emit_status(
                "attempt="
                f"{attempt_index}/{len(attempts)}, mode={mode_name}, "
                f"client={current_client}, auth={auth_context}"
            )
            attempt_logger = SilentLogger()
            try:
                known_paths_before = {p.resolve() for p in output_dir.glob("*") if p.is_file()}
                with yt_dlp.YoutubeDL(
                    build_ydl_opts(format_selector, client, browser, attempt_logger)
                ) as ydl:
                    info = ydl.extract_info(normalized_url, download=True)
                    output_path = resolve_downloaded_file_path(
                        info, ydl, output_dir, known_paths_before
                    )
                    height = extract_selected_height(info) or probe_height_with_ffprobe(
                        output_path
                    )
                    format_id = extract_selected_format_id(info)

                    if requires_exact_match and height != effective_target_quality:
                        remove_file_if_exists(output_path)
                        actual_height = "unknown" if height is None else str(height)
                        reason = (
                            f"client={current_client}, auth={auth_context}, mode={mode_name}: "
                            f"actual_quality={actual_height} does_not_match_target={effective_target_quality}"
                        )
                        attempt_reasons.append(reason)
                        emit_status(f"quality_retry={reason}")
                        continue

                    if (
                        not requires_exact_match
                        and height is not None
                        and height > effective_target_quality
                    ):
                        remove_file_if_exists(output_path)
                        reason = (
                            f"client={current_client}, auth={auth_context}, mode={mode_name}: "
                            f"actual_quality={height} above_target={effective_target_quality}"
                        )
                        attempt_reasons.append(reason)
                        emit_status(f"quality_retry={reason}")
                        continue

                    fallback = False
                    fallback_reason = None
                    if height is not None and height < effective_target_quality:
                        fallback = True
                        fallback_reason = (
                            f"requested={effective_target_quality}, actual={height}"
                        )
                    elif not requires_exact_match and effective_quality_policy == "strict":
                        fallback = True
                        fallback_reason = (
                            f"exact_target_unavailable, requested={effective_target_quality}"
                        )

                    selected_height = "unknown" if height is None else str(height)
                    selected_format = format_id if format_id else "unknown"
                    emit_status(
                        f"selected_client={current_client}, selected_auth={auth_context}, "
                        f"requested_quality={effective_target_quality}, "
                        f"actual_quality={selected_height}, selected_format={selected_format}, "
                        f"quality_fallback={'yes' if fallback else 'no'}"
                    )
                    return DownloadOutcome(
                        path=output_path,
                        client=current_client,
                        auth_context=auth_context,
                        height=height,
                        format_id=format_id,
                        target_quality=effective_target_quality,
                        quality_policy=effective_quality_policy,
                        fallback=fallback,
                        fallback_reason=fallback_reason,
                    )
            except DownloadError as exc:
                last_error = exc
                message = clean_error_message(str(exc))
                reason = (
                    f"client={current_client}, auth={auth_context}, mode={mode_name}: {message}"
                )
                attempt_reasons.append(reason)
                retryable = is_retryable_download_error(message)
                emit_status(
                    f"attempt_error=client={current_client}, auth={auth_context}, "
                    f"retryable={'yes' if retryable else 'no'}, reason={message}"
                )
                if retryable:
                    continue
                raise

    _ = allow_strict_relaxation
    summary = "; ".join(attempt_reasons[-4:]) if attempt_reasons else "no details"
    raise SystemExit(
        "No compatible format found for requested quality "
        f"{effective_target_quality}. Recent reasons: {summary}"
    ) from last_error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download YouTube video as MP4 with target quality and fallback policy."
    )
    parser.add_argument("url", help="YouTube video URL")
    parser.add_argument(
        "--cookies-from-browser",
        dest="cookies_from_browser",
        default=None,
        help="Browser name for yt-dlp cookies import, e.g. chrome, safari, firefox",
    )
    parser.add_argument(
        "--target-quality",
        dest="target_quality",
        type=int,
        default=None,
        help=f"Requested output height ({MIN_TARGET_QUALITY}..{MAX_TARGET_QUALITY}), default={DEFAULT_TARGET_QUALITY}.",
    )
    parser.add_argument(
        "--min-height",
        dest="min_height",
        type=int,
        default=None,
        help="Legacy alias for --target-quality.",
    )
    parser.add_argument(
        "--quality-policy",
        dest="quality_policy",
        choices=["strict", "best_effort"],
        default=None,
        help="strict: fail below min-height, best_effort: allow lower quality",
    )
    parser.add_argument(
        "--player-client",
        action="append",
        dest="player_clients",
        default=None,
        help="yt-dlp YouTube client(s), e.g. web, android, ios. Can be repeated.",
    )
    parser.add_argument(
        "--po-token-android",
        dest="po_token_android",
        default=None,
        help="YouTube PO token for android client (also read from YT_PO_TOKEN_ANDROID).",
    )
    parser.add_argument(
        "--po-token-ios",
        dest="po_token_ios",
        default=None,
        help="YouTube PO token for ios client (also read from YT_PO_TOKEN_IOS).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    po_token_android = args.po_token_android or os.getenv("YT_PO_TOKEN_ANDROID")
    po_token_ios = args.po_token_ios or os.getenv("YT_PO_TOKEN_IOS")
    try:
        result = download_youtube_mp4_720p(
            args.url,
            cookies_from_browser=args.cookies_from_browser,
            target_quality=args.target_quality,
            min_height=args.min_height,
            quality_policy=args.quality_policy,
            player_clients=args.player_clients,
            po_token_android=po_token_android,
            po_token_ios=po_token_ios,
        )
    except DownloadError as exc:
        raise SystemExit(str(exc)) from exc
    selected_height = result.height if result.height is not None else None
    selected_format = result.format_id if result.format_id else "unknown"
    cookies_used = result.auth_context.startswith("cookies:")
    if result.fallback and result.fallback_reason:
        emit_status(f"quality_fallback_reason={result.fallback_reason}")

    output_payload = {
        "file_path": str(result.path),
        "target_quality": result.target_quality,
        "actual_quality": selected_height,
        "fallback": result.fallback,
        "fallback_reason": result.fallback_reason,
        "selected_client": result.client,
        "selected_auth": result.auth_context,
        "selected_format": selected_format,
        "cookies_used": cookies_used,
    }
    print(json.dumps(output_payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
