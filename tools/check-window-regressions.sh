#!/bin/bash
# Native UI checks use synthetic data and never synthesize keyboard events.
set -euo pipefail
tools_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$tools_dir/run-window-regressions.py"
