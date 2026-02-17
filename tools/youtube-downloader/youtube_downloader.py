#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
from urllib.parse import urlparse

import yt_dlp
from yt_dlp.utils import DownloadError


def normalize_youtube_url(url: str) -> str:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path_parts = [part for part in parsed.path.split("/") if part]

    if "youtube.com" in host and len(path_parts) >= 2 and path_parts[0] == "live":
        video_id = path_parts[1]
        return f"https://www.youtube.com/watch?v={video_id}"
    return url


def download_youtube_mp4_720p(url: str, cookies_from_browser: str | None = None) -> Path:
    normalized_url = normalize_youtube_url(url)
    script_dir = Path(__file__).resolve().parent
    output_dir = script_dir / "out"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(output_dir / "%(title)s.%(ext)s")

    ydl_opts = {
        "format": "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/b[height<=720]",
        "outtmpl": output_template,
        "merge_output_format": "mp4",
        "noplaylist": True,
        "restrictfilenames": True,
        "extractor_args": {
            "youtube": {
                "player_client": ["android", "ios", "web"],
            }
        },
        "retries": 3,
        "fragment_retries": 3,
    }
    if cookies_from_browser:
        ydl_opts["cookiesfrombrowser"] = (cookies_from_browser,)

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(normalized_url, download=True)
            output_path = Path(ydl.prepare_filename(info))
            if output_path.suffix.lower() != ".mp4":
                output_path = output_path.with_suffix(".mp4")
            return output_path
    except DownloadError as exc:
        message = str(exc)
        if "HTTP Error 403" in message:
            raise SystemExit(
                "YouTube blocked direct stream request (HTTP 403). "
                "Try running again later or use --cookies-from-browser (for example: chrome)."
            ) from exc
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download YouTube video as MP4 up to 720p into ./out."
    )
    parser.add_argument("url", help="YouTube video URL")
    parser.add_argument(
        "--cookies-from-browser",
        dest="cookies_from_browser",
        default=None,
        help="Browser name for yt-dlp cookies import, e.g. chrome, safari, firefox",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    saved_path = download_youtube_mp4_720p(args.url, args.cookies_from_browser)
    print(f"Saved: {saved_path}")


if __name__ == "__main__":
    main()
