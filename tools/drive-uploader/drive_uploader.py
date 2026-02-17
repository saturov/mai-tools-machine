#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import json
import mimetypes
import os
import random
import sys
import time
from pathlib import Path
from typing import Any, Literal

import google.auth
from google.auth.transport.requests import Request
from google.oauth2 import credentials as user_credentials
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload
from google_auth_oauthlib.flow import InstalledAppFlow


AuthMode = Literal["oauth", "adc", "service_account"]

DEFAULT_SCOPES = ["https://www.googleapis.com/auth/drive.file"]


def _eprint(message: str) -> None:
    print(message, file=sys.stderr)


def _default_token_path() -> Path:
    return Path("~/.config/my-tools-sandbox/drive-uploader/token.json").expanduser()


def _guess_mime_type(file_path: Path) -> str | None:
    mime, _ = mimetypes.guess_type(str(file_path))
    return mime


def _load_oauth_credentials(
    *,
    scopes: list[str],
    client_secret_path: Path,
    token_path: Path,
    no_browser: bool,
    timeout_seconds: int,
) -> Any:
    creds: Any | None = None
    if token_path.exists():
        try:
            creds = user_credentials.Credentials.from_authorized_user_file(
                str(token_path), scopes=scopes
            )
        except Exception as exc:  # token file could be corrupted/partial
            raise RuntimeError(f"Failed to read token file: {token_path}") from exc

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
        except Exception:
            creds = None

    if creds and creds.valid:
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(creds.to_json(), encoding="utf-8")
        return creds

    if not client_secret_path.exists():
        raise FileNotFoundError(
            f"OAuth client secret JSON not found: {client_secret_path}\n"
            "Tip: place it as tools/drive-uploader/client_secret.json or pass --credentials-path."
        )

    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret_path), scopes=scopes)

    # Keep stdout clean for JSON output: library prompts get redirected to stderr.
    with contextlib.redirect_stdout(sys.stderr):
        creds = flow.run_local_server(
            port=0,
            open_browser=not no_browser,
            timeout_seconds=timeout_seconds,
            authorization_prompt_message=(
                "Authorize this app by visiting this URL:\n{url}\n"
            ),
            success_message="Authorization complete. You may close this window.",
        )

    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(creds.to_json(), encoding="utf-8")
    return creds


def _load_adc_credentials(*, scopes: list[str]) -> Any:
    creds, _project = google.auth.default(scopes=scopes)
    return creds


def _load_service_account_credentials(
    *,
    scopes: list[str],
    key_path: Path | None,
) -> Any:
    resolved_key_path = key_path
    if resolved_key_path is None:
        env_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if env_path:
            resolved_key_path = Path(env_path).expanduser()
    if resolved_key_path is None:
        raise RuntimeError(
            "Service account key not provided. Set GOOGLE_APPLICATION_CREDENTIALS or pass --credentials-path."
        )
    if not resolved_key_path.exists():
        raise FileNotFoundError(f"Service account key JSON not found: {resolved_key_path}")
    return service_account.Credentials.from_service_account_file(
        str(resolved_key_path), scopes=scopes
    )


def _get_credentials(
    *,
    auth_mode: AuthMode,
    credentials_path: Path | None,
    token_path: Path,
    no_browser: bool,
    timeout_seconds: int,
) -> Any:
    if auth_mode == "oauth":
        if credentials_path is not None:
            client_secret_path = credentials_path
        else:
            script_dir = Path(__file__).resolve().parent
            candidate = script_dir / "client_secret.json"
            if candidate.exists():
                client_secret_path = candidate
            else:
                repo_root = script_dir.parents[1]  # .../tools/ -> repo root
                client_secret_path = repo_root / "client_secret.json"
        return _load_oauth_credentials(
            scopes=DEFAULT_SCOPES,
            client_secret_path=client_secret_path,
            token_path=token_path,
            no_browser=no_browser,
            timeout_seconds=timeout_seconds,
        )
    if auth_mode == "adc":
        return _load_adc_credentials(scopes=DEFAULT_SCOPES)
    if auth_mode == "service_account":
        return _load_service_account_credentials(scopes=DEFAULT_SCOPES, key_path=credentials_path)
    raise ValueError(f"Unsupported auth_mode: {auth_mode}")


def _should_retry_http(status: int) -> bool:
    return status in (408, 429, 500, 502, 503, 504)


def _sleep_backoff(attempt: int) -> None:
    # Exponential backoff with jitter: 0.5, 1, 2, 4, ... (cap ~30s)
    base = min(30.0, 0.5 * (2 ** max(0, attempt - 1)))
    time.sleep(base + random.random() * 0.25)


def _upload_file(
    *,
    file_path: Path,
    folder_id: str,
    name: str,
    mime_type: str | None,
    auth_mode: AuthMode,
    credentials_path: Path | None,
    token_path: Path,
    no_browser: bool,
    json_output: bool,
    resumable: bool,
    timeout_seconds: int,
    retries: int,
) -> dict[str, Any]:
    creds = _get_credentials(
        auth_mode=auth_mode,
        credentials_path=credentials_path,
        token_path=token_path,
        no_browser=no_browser,
        timeout_seconds=timeout_seconds,
    )

    service = build("drive", "v3", credentials=creds, cache_discovery=False)
    fields = "id,name,webViewLink,md5Checksum,size,mimeType,parents"

    metadata: dict[str, Any] = {"name": name, "parents": [folder_id]}
    media = MediaFileUpload(str(file_path), mimetype=mime_type, resumable=resumable)

    request = service.files().create(
        body=metadata,
        media_body=media,
        fields=fields,
        supportsAllDrives=True,
    )

    if not resumable:
        last_exc: Exception | None = None
        for attempt in range(1, retries + 2):
            try:
                return dict(request.execute())
            except HttpError as exc:
                last_exc = exc
                status = getattr(exc.resp, "status", None)
                if isinstance(status, int) and _should_retry_http(status) and attempt <= retries + 1:
                    _eprint(f"Drive API error {status}, retrying ({attempt}/{retries + 1})...")
                    _sleep_backoff(attempt)
                    continue
                raise
            except Exception as exc:
                last_exc = exc
                if attempt <= retries + 1:
                    _eprint(f"Upload failed, retrying ({attempt}/{retries + 1})...")
                    _sleep_backoff(attempt)
                    continue
                raise
        assert last_exc is not None
        raise last_exc

    response: dict[str, Any] | None = None
    last_progress: int | None = None
    for attempt in range(1, retries + 2):
        try:
            while response is None:
                status, chunk_response = request.next_chunk()
                if status is not None:
                    progress = int(status.progress() * 100)
                    if not json_output and (last_progress is None or progress != last_progress):
                        _eprint(f"Upload progress: {progress}%")
                    last_progress = progress
                if chunk_response is not None:
                    response = dict(chunk_response)
            break
        except HttpError as exc:
            status = getattr(exc.resp, "status", None)
            if isinstance(status, int) and _should_retry_http(status) and attempt <= retries + 1:
                _eprint(f"Drive API error {status}, retrying ({attempt}/{retries + 1})...")
                _sleep_backoff(attempt)
                continue
            raise
        except Exception:
            if attempt <= retries + 1:
                _eprint(f"Upload failed, retrying ({attempt}/{retries + 1})...")
                _sleep_backoff(attempt)
                continue
            raise

    if response is None:
        raise RuntimeError("Upload failed without a response.")
    return response


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload a file to a Google Drive folder.")
    parser.add_argument("--file-path", required=True, help="Local file path to upload")
    parser.add_argument("--folder-id", required=True, help="Target Google Drive folder ID")
    parser.add_argument("--name", default=None, help="Drive file name (default: basename of file)")
    parser.add_argument("--mime-type", default=None, help="MIME type (default: auto-detect)")
    parser.add_argument(
        "--auth-mode",
        choices=["oauth", "adc", "service_account"],
        default="oauth",
        help="Authentication mode (default: oauth)",
    )
    parser.add_argument(
        "--credentials-path",
        default=None,
        help=(
            "For oauth: OAuth client secret JSON. "
            "For service_account: service account key JSON. "
            "If omitted in oauth mode, uses ./client_secret.json next to this script."
        ),
    )
    parser.add_argument(
        "--token-path",
        default=str(_default_token_path()),
        help="Path to store OAuth token JSON (default: ~/.config/.../token.json)",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Do not auto-open browser during OAuth flow (prints URL to authorize).",
    )
    parser.add_argument(
        "--json",
        dest="json_output",
        action="store_true",
        default=True,
        help="Print JSON to stdout (default).",
    )
    parser.add_argument(
        "--no-json",
        dest="json_output",
        action="store_false",
        help="Print human-readable output.",
    )
    parser.add_argument(
        "--resumable",
        action="store_true",
        default=True,
        help="Use resumable upload (default).",
    )
    parser.add_argument(
        "--no-resumable",
        dest="resumable",
        action="store_false",
        help="Disable resumable upload.",
    )
    parser.add_argument("--timeout-seconds", type=int, default=120, help="OAuth local server timeout.")
    parser.add_argument("--retries", type=int, default=3, help="Retry count for transient errors.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    file_path = Path(args.file_path).expanduser()
    if not file_path.exists() or not file_path.is_file():
        _eprint(f"File not found: {file_path}")
        return 2

    name = args.name or file_path.name
    mime_type = args.mime_type or _guess_mime_type(file_path)

    credentials_path = Path(args.credentials_path).expanduser() if args.credentials_path else None
    token_path = Path(args.token_path).expanduser()

    try:
        response = _upload_file(
            file_path=file_path,
            folder_id=args.folder_id,
            name=name,
            mime_type=mime_type,
            auth_mode=args.auth_mode,
            credentials_path=credentials_path,
            token_path=token_path,
            no_browser=bool(args.no_browser),
            json_output=bool(args.json_output),
            resumable=bool(args.resumable),
            timeout_seconds=int(args.timeout_seconds),
            retries=int(args.retries),
        )
    except FileNotFoundError as exc:
        _eprint(str(exc))
        return 3
    except HttpError as exc:
        status = getattr(exc.resp, "status", None)
        message = f"Drive API error{f' {status}' if status else ''}: {exc}"
        _eprint(message)
        return 4
    except Exception as exc:
        _eprint(f"Error: {exc}")
        return 1

    out: dict[str, Any] = {
        "file_id": response.get("id", ""),
        "file_name": response.get("name", ""),
    }
    if response.get("webViewLink"):
        out["web_view_link"] = response.get("webViewLink")
    if response.get("mimeType"):
        out["mime_type"] = response.get("mimeType")
    if response.get("size") is not None:
        out["size_bytes"] = str(response.get("size"))
    if response.get("md5Checksum"):
        out["md5_checksum"] = response.get("md5Checksum")
    if response.get("parents"):
        out["parents"] = response.get("parents")

    if args.json_output:
        print(json.dumps(out, ensure_ascii=False))
    else:
        _eprint("Uploaded successfully.")
        print(json.dumps(out, ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
