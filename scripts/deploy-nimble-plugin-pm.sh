#!/usr/bin/env bash
# NimbleStoragePlugin.pm + GUI (NimbleEdit.js and its index.html.tpl tag): install + restart here,
# then scp to pve001 and pve003 and same there.
# Intended: run on pve002 with passwordless root SSH to pve001 / pve003.
#
#   sudo ./deploy-nimble-plugin-pm.sh            # files from this repo checkout (default)
#   sudo ./deploy-nimble-plugin-pm.sh --github   # download files from GitHub instead
#
set -euo pipefail

GITHUB=0
case "${1-}" in
  --github) GITHUB=1 ;;
  "") ;;
  *) echo "Usage: $0 [--github]" >&2; exit 1 ;;
esac
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
readonly DEFAULT_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/NimbleStoragePlugin.pm'
readonly DEFAULT_BASE='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main'
PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_URL}"
GUI_JS_URL="${GUI_JS_URL:-$DEFAULT_BASE/www/NimbleEdit.js}"
GUI_INSTALLER_URL="${GUI_INSTALLER_URL:-$DEFAULT_BASE/scripts/install-nimble-gui.sh}"
REMOTES="${REMOTES:-pve001 pve003}"
THIS="$(hostname -s 2>/dev/null || hostname)"

SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)

SSH_OPTS=( -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new )

restart_stack() {
  if command -v deb-systemd-invoke >/dev/null 2>&1; then
    for s in "${SERVICES[@]}"; do deb-systemd-invoke try-restart "${s}.service" 2>/dev/null || true; done
  else
    for s in "${SERVICES[@]}"; do systemctl try-restart "${s}.service" 2>/dev/null || true; done
  fi
}

download_to() {
  local out="$1" url="${2:-$PLUGIN_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 120 -o "$out" -- "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=120 -O "$out" -- "$url"
  else
    echo "Need curl or wget" >&2
    exit 1
  fi
}

install_from_tmp() {
  local tmp="$1"
  head -n 1 "$tmp" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin' || {
    echo "Not NimbleStoragePlugin.pm" >&2
    exit 1
  }
  install -d -m 755 "$(dirname "$TARGET")"
  install -m 644 "$tmp" "$TARGET"
}

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v pveversion >/dev/null 2>&1 || { echo "Not a PVE host?" >&2; exit 1; }

if [[ "$GITHUB" -eq 1 ]]; then
  tmp=$(mktemp)
  gui_js=$(mktemp)
  gui_sh=$(mktemp)
  trap 'rm -f "$tmp" "$gui_js" "$gui_sh"' EXIT
  echo "Local: download -> $TARGET"
  download_to "$tmp"
  download_to "$gui_js" "$GUI_JS_URL"
  download_to "$gui_sh" "$GUI_INSTALLER_URL"
else
  tmp="$REPO_DIR/NimbleStoragePlugin.pm"
  gui_js="$REPO_DIR/www/NimbleEdit.js"
  gui_sh="$REPO_DIR/scripts/install-nimble-gui.sh"
  for f in "$tmp" "$gui_js" "$gui_sh"; do
    [[ -f "$f" ]] || { echo "Missing $f (run from a repo checkout, or use --github)" >&2; exit 1; }
  done
  echo "Local: repo copy $REPO_DIR -> $TARGET"
fi
install_from_tmp "$tmp"
# Installs NimbleEdit.js, injects the <script> tag into index.html.tpl, restarts pveproxy.
bash "$gui_sh" --js "$gui_js"
restart_stack
echo "Local: done."

echo "Also pushing to: $REMOTES"

for h in $REMOTES; do
  [[ -n "$h" ]] || continue
  if [[ "$h" == "$THIS" ]]; then
    echo "Skip $h (same as this host)"
    continue
  fi
  echo "Remote $h: scp then install + restart"
  scp "${SSH_OPTS[@]}" "$TARGET" "root@${h}:/tmp/NimbleStoragePlugin.new" || {
    echo "ERROR: scp to root@${h} failed (keys? DNS? firewall?)" >&2
    exit 1
  }
  scp "${SSH_OPTS[@]}" "$gui_js" "root@${h}:/tmp/NimbleEdit.js" || exit 1
  scp "${SSH_OPTS[@]}" "$gui_sh" "root@${h}:/tmp/install-nimble-gui.sh" || exit 1
  ssh "${SSH_OPTS[@]}" "root@${h}" bash -s <<'REMOTE'
set -euo pipefail
T='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
install -d -m 755 "$(dirname "$T")"
install -m 644 /tmp/NimbleStoragePlugin.new "$T"
rm -f /tmp/NimbleStoragePlugin.new
bash /tmp/install-nimble-gui.sh --js /tmp/NimbleEdit.js
rm -f /tmp/NimbleEdit.js /tmp/install-nimble-gui.sh
if command -v deb-systemd-invoke >/dev/null 2>&1; then
  for s in pvedaemon pvestatd pveproxy pvescheduler; do
    deb-systemd-invoke try-restart "${s}.service" 2>/dev/null || true
  done
else
  for s in pvedaemon pvestatd pveproxy pvescheduler; do
    systemctl try-restart "${s}.service" 2>/dev/null || true
  done
fi
echo "remote: OK"
REMOTE
  echo "Remote $h: done."
done

echo "All done."
