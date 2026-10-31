#!/usr/bin/env bash
set -euo pipefail
# Always create a private bus and virtual X11 server for synthetic shell checks.
export CLIPBOARD_PRIVATE_SHELL_TEST=1
exec dbus-run-session -- xvfb-run --auto-servernum \
  /usr/bin/python3 "$(dirname "$0")/check-linux-tray.py" "$@"
