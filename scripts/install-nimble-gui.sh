#!/usr/bin/env bash
# Install (or remove) the HPE Nimble Web UI panel on Proxmox VE nodes.
#
# The .deb does this in postinst; use this script when the plugin was installed another way
# (scp / install-pve-nimble-plugin.sh) or when a release package predates the GUI (<= v0.0.25).
#
# It copies www/NimbleEdit.js to /usr/share/pve-manager/js/ and adds a <script> tag for it to
# /usr/share/pve-manager/index.html.tpl, directly AFTER the pvemanagerlib.js tag (the panel extends
# PVE classes, so it must load after them), then restarts pveproxy. A pve-manager upgrade replaces
# the template and drops the tag; an apt hook re-adds it automatically (disable with --no-hook).
#
#   sudo ./scripts/install-nimble-gui.sh                      # this node
#   sudo ./scripts/install-nimble-gui.sh --remotes "hou-proxmox1 hou-proxmox2"   # these nodes over ssh
#   sudo ./scripts/install-nimble-gui.sh --uninstall          # remove (add --remotes for other nodes)
#   sudo ./scripts/install-nimble-gui.sh --status
#
# Options:
#   --js FILE        NimbleEdit.js to install (default: ../www/NimbleEdit.js next to this script)
#   --remotes "A B"  also run on these hosts via ssh as root (needs key-based login)
#   --no-hook        do not install the apt hook that re-adds the tag after pve-manager upgrades
#   --no-restart     do not restart pveproxy (reload the page after restarting it yourself)
#   --uninstall      remove the tag, the JS file and the apt hook
#   --status         show what is installed
set -euo pipefail

JS_DIR="${JS_DIR:-/usr/share/pve-manager/js}"
TPL="${TPL:-/usr/share/pve-manager/index.html.tpl}"
JS_NAME="NimbleEdit.js"
MARKER="$JS_NAME"
TAG='    <script type="text/javascript" src="/pve2/js/NimbleEdit.js"></script>'
HOOK_FILE="${HOOK_FILE:-/etc/apt/apt.conf.d/99nimble-gui}"
HELPER="${HELPER:-/usr/local/sbin/nimble-gui-install}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SRC_JS="$(dirname "$SCRIPT_PATH")/../www/$JS_NAME"
ACTION=install
REMOTES=""
HOOK=1
RESTART=1
INJECT_ONLY=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --js)          SRC_JS="${2:?--js needs a file}"; shift 2 ;;
    --remotes)     REMOTES="${2:?--remotes needs a host list}"; shift 2 ;;
    --no-hook)     HOOK=0; shift ;;
    --no-restart)  RESTART=0; shift ;;
    --uninstall)   ACTION=uninstall; shift ;;
    --status)      ACTION=status; shift ;;
    --inject-only) INJECT_ONLY=1; shift ;;   # used by the apt hook
    -h|--help)     sed -n '2,/^set -euo/p' "$SCRIPT_PATH" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

restart_proxy() {
  [ "$RESTART" -eq 1 ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl restart pveproxy.service
}

tag_present() { [ -f "$TPL" ] && grep -qF "$MARKER" "$TPL"; }

# Add the tag after the pvemanagerlib.js line; fall back to just before </head>.
inject_tag() {
  [ -f "$TPL" ] || die "$TPL not found (is this a Proxmox VE node?)"
  tag_present && return 1
  cp -a "$TPL" "$TPL.nimble-gui.bak"
  if grep -q 'pvemanagerlib\.js' "$TPL"; then
    # a<newline>text appends after every matching line; the lib is normally referenced once
    sed -i "/pvemanagerlib\.js/a\\
${TAG}" "$TPL"
  elif grep -q '</head>' "$TPL"; then
    sed -i "s|</head>|${TAG}\n  </head>|" "$TPL"
  else
    die "no pvemanagerlib.js reference or </head> in $TPL; refusing to guess where the tag goes"
  fi
  tag_present || die "tag was not written to $TPL (backup: $TPL.nimble-gui.bak)"
  return 0
}

remove_tag() {
  [ -f "$TPL" ] || return 1
  tag_present || return 1
  sed -i "/${MARKER//./\\.}/d" "$TPL"
  return 0
}

install_hook() {
  [ "$HOOK" -eq 1 ] || return 0
  [ -d "$(dirname "$HOOK_FILE")" ] || return 0
  install -m 755 "$SCRIPT_PATH" "$HELPER"
  cat > "$HOOK_FILE" <<EOF
// Re-add the HPE Nimble GUI script tag after a pve-manager upgrade replaces index.html.tpl.
DPkg::Post-Invoke { "[ -x $HELPER ] && $HELPER --inject-only >/dev/null 2>&1 || true"; };
EOF
}

do_status() {
  printf 'JS file : '; [ -f "$JS_DIR/$JS_NAME" ] && echo "present ($JS_DIR/$JS_NAME)" || echo "MISSING"
  printf 'Tag     : '; tag_present && echo "present in $TPL" || echo "MISSING from $TPL"
  printf 'apt hook: '; [ -f "$HOOK_FILE" ] && echo "installed" || echo "not installed"
  if command -v curl >/dev/null 2>&1 && [ "$TPL" = /usr/share/pve-manager/index.html.tpl ]; then
    printf 'Served  : '
    curl -sk -o /dev/null -w '%{http_code}\n' "https://localhost:8006/pve2/js/$JS_NAME" || echo "n/a"
  fi
}

do_install() {
  [ -f "$SRC_JS" ] || die "$SRC_JS not found (use --js FILE)"
  head -c 400 "$SRC_JS" | grep -q "Nimble" || die "$SRC_JS does not look like NimbleEdit.js"
  install -d -m 755 "$JS_DIR"
  install -m 644 "$SRC_JS" "$JS_DIR/$JS_NAME"
  if inject_tag; then echo "Tag added to $TPL"; else echo "Tag already present in $TPL"; fi
  install_hook
  restart_proxy
  echo "Done. Hard-refresh the browser (Ctrl+Shift+R): Datacenter -> Storage -> Add -> HPE Nimble."
}

do_uninstall() {
  remove_tag && echo "Tag removed from $TPL" || echo "No tag in $TPL"
  rm -f "$JS_DIR/$JS_NAME" "$HOOK_FILE" "$HELPER"
  restart_proxy
  echo "Done."
}

run_remote() {
  local host="$1" tmp
  local ssh_opts=( -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new )
  tmp="$(ssh "${ssh_opts[@]}" "root@$host" mktemp -d)" || die "cannot ssh to root@$host"
  scp "${ssh_opts[@]}" -q "$SCRIPT_PATH" "root@$host:$tmp/install-nimble-gui.sh"
  [ "$ACTION" = install ] && scp "${ssh_opts[@]}" -q "$SRC_JS" "root@$host:$tmp/$JS_NAME"
  local args=()
  case "$ACTION" in
    install)   args=( --js "$tmp/$JS_NAME" ) ;;
    uninstall) args=( --uninstall ) ;;
    status)    args=( --status ) ;;
  esac
  [ "$HOOK" -eq 0 ] && args+=( --no-hook )
  [ "$RESTART" -eq 0 ] && args+=( --no-restart )
  echo "== $host"
  ssh "${ssh_opts[@]}" "root@$host" "bash $tmp/install-nimble-gui.sh ${args[*]}; rc=\$?; rm -rf $tmp; exit \$rc"
}

# --- apt hook entry point: add the tag back if an upgrade removed it ---
if [ "$INJECT_ONLY" -eq 1 ]; then
  inject_tag && restart_proxy
  exit 0
fi

if [ "$ACTION" != status ] && [ "$(id -u)" -ne 0 ] && [ "$TPL" = /usr/share/pve-manager/index.html.tpl ]; then
  die "run as root (sudo)"
fi

if [ "$ACTION" = status ]; then do_status
elif [ "$ACTION" = uninstall ]; then do_uninstall
else do_install; fi

for h in $REMOTES; do run_remote "$h"; done
