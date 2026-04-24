#!/usr/bin/env bash
# Clipboard installer
#   curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
#
# Downloads the latest release DMG from GitHub, verifies its SHA-256,
# quits any running Clipboard, installs to /Applications, and strips
# the Gatekeeper quarantine attribute (because the DMG is unsigned).

set -euo pipefail

REPO="carter-ya/clipboard"
APP_NAME="Clipboard"
DEST="/Applications/${APP_NAME}.app"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Run a command directly, or under sudo if /Applications is not writable.
# Wrapped as a function so we avoid bash 3.2's broken empty-array expansion
# under `set -u` (the default /bin/bash on macOS is 3.2.57).
privileged() {
  if [[ -w /Applications ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer only supports macOS."

  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 13 ]] \
    || die "Clipboard requires macOS 13 or later (detected $(sw_vers -productVersion))."

  TMP="$(mktemp -d -t clipboard-install.XXXXXX)"
  MOUNT_POINT="${TMP}/mnt"

  cleanup() {
    hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$TMP"
  }
  trap cleanup EXIT

  say "Resolving latest release..."
  local latest_url tag version dmg_name dmg_url sha_url expected actual
  latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest")"
  tag="${latest_url##*/tag/}"
  tag="${tag%%\?*}"  # strip any query string
  tag="${tag%%/*}"   # strip any trailing path segment
  [[ -n "$tag" && "$tag" != "$latest_url" ]] \
    || die "Could not resolve latest tag from ${latest_url}"
  version="${tag#v}"
  dmg_name="${APP_NAME}-${version}.dmg"
  dmg_url="https://github.com/${REPO}/releases/download/${tag}/${dmg_name}"
  sha_url="${dmg_url}.sha256"
  ok "Found ${tag}"

  say "Downloading ${dmg_name}..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar \
    -o "${TMP}/${dmg_name}" "$dmg_url"
  curl -fsSL --retry 3 --retry-delay 2 \
    -o "${TMP}/${dmg_name}.sha256" "$sha_url"

  say "Verifying SHA-256..."
  expected="$(awk '{print $1}' "${TMP}/${dmg_name}.sha256")"
  actual="$(shasum -a 256 "${TMP}/${dmg_name}" | awk '{print $1}')"
  [[ -n "$expected" ]] || die "Empty checksum in ${dmg_name}.sha256"
  [[ "$expected" == "$actual" ]] \
    || die "SHA-256 mismatch (expected ${expected}, got ${actual})"
  ok "Checksum OK (${expected:0:12}...)"

  # Match only the installed app, not arbitrary processes also named "Clipboard".
  local running_pattern="^${DEST}/Contents/MacOS/${APP_NAME}\$"
  if pgrep -f "$running_pattern" >/dev/null 2>&1; then
    say "Quitting running ${APP_NAME}..."
    pkill -TERM -f "$running_pattern" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "$running_pattern" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if pgrep -f "$running_pattern" >/dev/null 2>&1; then
      warn "App did not exit after SIGTERM; sending SIGKILL..."
      pkill -KILL -f "$running_pattern" >/dev/null 2>&1 || true
      sleep 0.5
    fi
  fi

  say "Mounting ${dmg_name}..."
  hdiutil attach -nobrowse -readonly -noautoopen \
    -mountpoint "$MOUNT_POINT" "${TMP}/${dmg_name}" >/dev/null \
    || die "Failed to mount ${dmg_name}"

  local src="${MOUNT_POINT}/${APP_NAME}.app"
  [[ -d "$src" ]] || die "${APP_NAME}.app not found inside DMG"

  if [[ ! -w /Applications ]]; then
    warn "/Applications is not writable by $(whoami); will prompt for sudo."
  fi

  say "Installing to ${DEST}..."
  # Stage the new copy next to DEST, then swap atomically so an interrupted
  # install (disk full, Ctrl-C, bad DMG) never leaves us with the old app
  # gone and the new app half-written. ditto preserves xattr / ACLs / resource
  # forks, which matter for .app bundles (code signatures, LS metadata).
  local staging="${DEST}.install-$$"
  local backup="${DEST}.old-$$"
  privileged rm -rf "$staging" "$backup"
  privileged ditto "$src" "$staging"
  if [[ -e "$DEST" ]]; then
    privileged mv "$DEST" "$backup"
  fi
  privileged mv "$staging" "$DEST"
  privileged rm -rf "$backup"

  # When installed via sudo the bundle ends up owned by root; normalise to the
  # invoking user so Sparkle can write in-place updates without re-elevating.
  if [[ ! -w /Applications ]]; then
    privileged chown -R "$(id -un):staff" "$DEST"
  fi

  hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true

  say "Clearing Gatekeeper quarantine attribute..."
  privileged xattr -cr "$DEST"

  ok ""
  ok "Clipboard ${version} installed."
  ok "Launch via Launchpad / Spotlight, or run:  open -a ${APP_NAME}"
}

main "$@"
