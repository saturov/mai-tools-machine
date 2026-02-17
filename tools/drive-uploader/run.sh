#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PYTHON="${PYTHON:-python3}"
VENV_DIR="${VENV_DIR:-.venv}"
VENV_PY="$VENV_DIR/bin/python"
PIP="$VENV_PY -m pip"

if [[ ! -x "$VENV_PY" ]]; then
  "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
    echo "Error: Python 3.10+ is required. Current: $("$PYTHON" -V 2>&1)" >&2
    exit 1
  }
  "$PYTHON" -m venv "$VENV_DIR"
  $PIP install --upgrade pip >/dev/null
fi

$VENV_PY -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
  echo "Error: .venv uses Python < 3.10. Recreate it (rm -rf .venv) and retry." >&2
  exit 1
}

$PIP install -r requirements.txt >/dev/null

$VENV_PY drive_uploader.py "$@"

