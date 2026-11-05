#!/bin/sh
# One-time setup: Python env + Swift build. Models download on first run.
set -e
cd "$(dirname "$0")"

PY=""
for v in python3.12 python3.13 python3.11 python3.10; do
    if command -v "$v" >/dev/null 2>&1; then PY="$v"; break; fi
done
[ -n "$PY" ] || { echo "Need Python 3.10–3.13 (e.g. brew install python@3.12)"; exit 1; }

echo "Creating .venv with $PY…"
"$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

echo "Building LiveSubs…"
./build.sh

command -v ollama >/dev/null 2>&1 || echo "Note: install Ollama (https://ollama.com) for translation."
echo "Done. Run ./LiveSubs from Terminal."
