#!/usr/bin/env bash
##############################################################################
# PVE Nimble Storage Plugin Installer
# Copyright (c) pve-nimble-plugin contributors
#
# Validate supported PVE release, add APT repo (or install .deb from GitHub),
# and install libpve-storage-nimble-perl. Supports single-node and
# cluster-wide install (all nodes via SSH).
##############################################################################

##########################################################
# shell modes
##########################################################
set -o errtrace
set -o errexit

##########################################################
# exports
##########################################################
export http_proxy
export https_proxy
export all_proxy
export ftp_proxy
export no_proxy

##########################################################
# defines
##########################################################
readonly SCRIPT_VERSION="1.1"
readonly OS_RELEASE_FILE=/etc/os-release
readonly SOURCES_LIST=/etc/apt/sources.list.d/pve-nimble-plugin.list
# Same set/order as pve-purestorage-plugin debian/postinst (no pve-cluster); see debian/postinst in this repo.
readonly RESTARTED_SERVICES="pvedaemon pvestatd pveproxy pvescheduler"
readonly PVE_MEMBERS_FILE=/etc/pve/.members
readonly PACKAGE_NAME=libpve-storage-nimble-perl
readonly REPO_BASE="${REPO_BASE:-https://brngates98.github.io/pve-nimble-plugin}"
readonly PM_TARGET=/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
readonly GUI_JS=/usr/share/pve-manager/js/NimbleEdit.js
readonly GUI_TPL=/usr/share/pve-manager/index.html.tpl
readonly GITHUB_RELEASES_BASE="${GITHUB_RELEASES_BASE:-https://github.com/brngates98/pve-nimble-plugin/releases/download}"

REPO_SUITE="${REPO_SUITE:-bookworm}"
REPO_SUITE_SET=0
REMOTE_NODE=

# avoid prompts from dpkg during package install
export DEBIAN_FRONTEND=noninteractive

##########################################################
# helpers
##########################################################
function log()
{
    if [ -z "$REMOTE_NODE" ]; then
        printf "%b\n" "$*"
    else
        printf "[REMOTE %s] %b\n" "$REMOTE_NODE" "$*"
    fi
}

function fail()
{
    log ""
    log "ERROR: $*"
    log ""
    exit 1
}

##########################################################
# usage
##########################################################
function usage()
{
    cat <<EOF
PVE Nimble Storage Plugin Installer $SCRIPT_VERSION

Options:
  -c, --codename SUITE          APT suite (default: bookworm)
  -V, --version X.Y.Z           Install specific release from GitHub (.deb) instead of APT repo
  -v, --verbose                 Enable verbose logging to stderr
  -l, --log-file FILE           Write installer logs to FILE
  -y, --yes                     Non-interactive mode; assume "yes" for confirmation
  -n, --dry-run                 Show what would be done; make no changes and skip prompts
  -a, --all-nodes               Install on all PVE cluster nodes via SSH
  -L, --local                   Install from the local repo copy this script lives in (no APT/GitHub)
      --local-dir DIR           Install from the local repo copy in DIR
  -g, --github                  Install from GitHub (APT repo or release) even if a local copy exists

Default source: the local repo copy when run from a checkout; GitHub only when you ask
for it (--github, --version, or the menu) or when there is no local copy (curl | bash).
  -s, --status                  Show install status (plugin, GUI, services) and exit
  -u, --uninstall               Remove the plugin and GUI from this node
  -h, --help                    Show this help and exit

With no options on a terminal, an interactive menu is shown.

Single node:
  curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash

All nodes (dry-run first):
  curl -fsSL ... | sudo bash -s -- --all-nodes --dry-run
  curl -fsSL ... | sudo bash -s -- --all-nodes
EOF
}

##########################################################
# issue
##########################################################
function issue()
{
    if [ -z "$REMOTE_NODE" ]; then
        local g="" b="" r=""
        [[ -t 1 ]] && { g=$'\e[32m'; b=$'\e[1m'; r=$'\e[0m'; }
        # Green HPE element, then the wordmark: bold "Hewlett Packard", regular "Enterprise"
        printf '%s' "$g"
        cat <<'LOGO'

  ████████████████████
  ██                ██
  ████████████████████
LOGO
        printf '%s\n  %sHewlett Packard%s\n  Enterprise\n\n' "$r" "$b" "$r"
        log "PVE Nimble Storage Plugin Installer $SCRIPT_VERSION"
        log ""
    fi
}

##########################################################
# verify system is running a supported OS and version
##########################################################
function preflight()
{
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root. Please re-run with sudo or as root."
    fi

    builtin command -v pveversion >/dev/null || fail "This does not appear to be a Proxmox VE installation (pveversion command not found)"

    if [ ! -f "$OS_RELEASE_FILE" ]; then
        fail "Failed to determine OS release version ($OS_RELEASE_FILE not found)"
    fi

    source "$OS_RELEASE_FILE"

    OS_DIST=${ID-unset}
    if [ "$OS_DIST" == "unset" ]; then
        fail "Failed to determine OS distribution (ID not found in $OS_RELEASE_FILE)"
    fi

    if [ "${OS_DIST}" != "debian" ]; then
        fail "Unsupported OS distribution (expected 'debian' but found '${OS_DIST}')"
    fi

    OS_CODENAME=${VERSION_CODENAME-unset}
    if [ "$OS_CODENAME" == "unset" ]; then
        fail "Failed to determine distribution version (VERSION_CODENAME not found in $OS_RELEASE_FILE)"
    fi

    # Auto-select the correct APT suite from the OS codename unless the caller
    # explicitly passed --codename.
    if [[ "$REPO_SUITE_SET" -eq 0 ]]; then
        case "$OS_CODENAME" in
            trixie)  REPO_SUITE="trixie" ;;
            *)       REPO_SUITE="bookworm" ;;
        esac
    fi
}

# Repo root this script is run from; empty when piped from curl (no file on disk)
function find_local_dir()
{
    [[ -f "${BASH_SOURCE[0]:-}" ]] || return 1
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
}

function valid_local_dir()
{
    local d="${1-}"
    [[ -n "$d" && -f "$d/NimbleStoragePlugin.pm" && -f "$d/www/NimbleEdit.js" \
        && -f "$d/scripts/install-nimble-gui.sh" ]]
}

# Switch to the local-copy source, resolving and validating LOCAL_DIR
function use_local()
{
    SOURCE=local
    [[ -n "$LOCAL_DIR" ]] || LOCAL_DIR=$(find_local_dir) || LOCAL_DIR=""
    valid_local_dir "$LOCAL_DIR" || fail "No usable local copy (need NimbleStoragePlugin.pm, www/NimbleEdit.js, scripts/install-nimble-gui.sh). Run from a repo checkout or pass --local-dir DIR."
}

# quote input for remote execution
function sh_quote()
{
    local s=${1-}
    printf "'%s'" "${s@Q}"
}

# Return a unique list of IPv4 addresses for all nodes in the cluster
function enumerate_cluster_nodes()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -l -MJSON -e '$/ = undef; my $j = from_json(<>); print(join "\n", map { $_->{ip} } values %{$j->{nodelist}});' "$PVE_MEMBERS_FILE"
}

# Return true if the current node is part of a cluster
function is_cluster()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -MJSON -e '$/ = undef; my $j = from_json(<>); exit(defined($j->{cluster}) ? 0 : 1);' \
        "$PVE_MEMBERS_FILE"
}

# Return true if the cluster is quorate
function is_cluster_quorate()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -MJSON -e '$/ = undef; my $j = from_json(<>); exit(defined($j->{cluster}->{quorate}) ? 0 : 1);' \
        "$PVE_MEMBERS_FILE"
}

# URL to fetch and run this installer remotely
function installer_url()
{
    local url="${INSTALLER_URL:-https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh}"
    echo "$url"
}

# Install plugin on all PVE nodes in the cluster (local + remotes via SSH)
function install_on_all_nodes()
{
    local -a local_ips
    local -a node_ips
    mapfile -t local_ips < <(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)

    if is_cluster; then
        if ! is_cluster_quorate; then
            fail "Cluster does not have quorum -- refusing to proceed."
        fi

        mapfile -t node_ips < <(enumerate_cluster_nodes)
        if [[ ${#node_ips[@]} -eq 0 ]]; then
            fail "No cluster nodes found in $PVE_MEMBERS_FILE"
        fi

        log "Installing on ${#node_ips[@]} node PVE cluster."
    else
        log "Installing on local node -- non-cluster deployment detected."
        log ""
        install_software
        return
    fi

    local -a rflags=()
    [[ -n "$REPO_SUITE" ]] && rflags+=(--codename "$REPO_SUITE")
    [[ -n "$INSTALL_VERSION" ]] && rflags+=(--version "$INSTALL_VERSION")
    [[ "$VERBOSE" -eq 1 ]] && rflags+=(--verbose)
    [[ "$YES" -eq 1 ]] && rflags+=(--yes)
    [[ "$DRY_RUN" -eq 1 ]] && rflags+=(--dry-run)
    [[ "$LOG_FILE_SET" -eq 1 ]] && rflags+=(--log-file "$LOG_FILE")

    local export_cmds=""
    local v val
    for v in http_proxy https_proxy all_proxy ftp_proxy no_proxy; do
        val="${!v}"
        if [[ -n "$val" ]]; then
            export_cmds+="export $v=$(sh_quote "$val"); "
        fi
    done

    local inst_url
    inst_url="$(installer_url)"

    local ip
    for ip in "${node_ips[@]}"; do
        local is_local=0
        local lip
        for lip in "${local_ips[@]}"; do
            if [[ "$ip" == "$lip" ]]; then
                is_local=1
                break
            fi
        done

        if [[ $is_local -eq 1 ]]; then
            if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
                log ""
                log "DRY-RUN: would install on local node ($ip)..."
            else
                log ""
                log "Installing on local node ($ip)..."
            fi
            install_software
        elif [[ "$SOURCE" == local ]]; then
            log ""
            log "Installing local copy on remote node ($ip)..."
            push_local_to_node "$ip"
        else
            local remote_cmd
            remote_cmd=$(printf '/usr/bin/curl -fsSL %s | bash -s -- -X %s %s' "$(installer_url)" "$ip" "${rflags[*]}")
            remote_cmd=$(sh_quote "$remote_cmd")
            log ""
            log "Installing on remote node ($ip)..."
            builtin command /usr/bin/ssh "root@${ip}" "$remote_cmd"
        fi
    done
}

###########################################################################
# check_existing_install: detect whether this is a fresh install, an
# upgrade with the correct repo already in place, or an upgrade that
# requires the sources list to be updated first.
#
# Outputs one of: fresh | upgrade | repo_update
###########################################################################
function check_existing_install()
{
    local pkg_status
    pkg_status=$(dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null || true)
    if [[ "$pkg_status" != "install ok installed" ]]; then
        echo "fresh"
        return
    fi
    # Package is installed — check whether the sources list exists and
    # references the correct repo base URL and suite.
    if [[ -f "$SOURCES_LIST" ]] \
        && grep -qF "$REPO_BASE" "$SOURCES_LIST" \
        && grep -qF "$REPO_SUITE" "$SOURCES_LIST"; then
        echo "upgrade"
    else
        echo "repo_update"
    fi
}

###########################################################################
# install_software: add APT repo and install package, or install .deb from GitHub
###########################################################################
function install_software()
{
    if [[ "${YES:-0}" -ne 1 ]] && [[ "${DRY_RUN:-0}" -ne 1 ]] && [[ -t 0 ]]; then
        read -r -p "Do you want to continue? (y/n): " choice
        if [[ "$choice" != "y" ]]; then
            log "Installation aborted."
            exit 1
        fi
    fi

    if [[ "$SOURCE" == local ]]; then
        install_local
    elif [[ -n "$INSTALL_VERSION" ]]; then
        install_from_github_deb
    else
        local mode
        mode=$(check_existing_install)
        case "$mode" in
            fresh)
                log "Fresh install — suite: $REPO_SUITE"
                ;;
            upgrade)
                log "$PACKAGE_NAME already installed. APT repo is correct (suite: $REPO_SUITE) — checking for upgrade."
                ;;
            repo_update)
                log "$PACKAGE_NAME already installed. APT repo needs updating to suite '$REPO_SUITE'."
                ;;
        esac
        install_from_apt_repo "$mode"
    fi
}

function install_from_apt_repo()
{
    local mode="${1:-fresh}"
    local step=1

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        case "$mode" in
            fresh)
                log "DRY-RUN: would write APT repo: deb [trusted=yes] $REPO_BASE $REPO_SUITE main -> $SOURCES_LIST"
                ;;
            repo_update)
                log "DRY-RUN: would update $SOURCES_LIST to: deb [trusted=yes] $REPO_BASE $REPO_SUITE main"
                ;;
            upgrade)
                log "DRY-RUN: APT repo already correct ($SOURCES_LIST, suite: $REPO_SUITE) — no change needed"
                ;;
        esac
        log "DRY-RUN: would update package lists: apt-get update -q"
        if [[ "$mode" == "fresh" ]]; then
            log "DRY-RUN: would install: apt-get install -y -q open-iscsi $PACKAGE_NAME"
        else
            log "DRY-RUN: would upgrade: apt-get install -y -q --only-upgrade $PACKAGE_NAME"
        fi
        log "DRY-RUN: would restart PVE services: systemctl try-reload-or-restart $RESTARTED_SERVICES"
        return
    fi

    case "$mode" in
        fresh)
            log "$((step++)). Adding PVE Nimble Plugin APT repository (suite: $REPO_SUITE)..."
            printf "deb [trusted=yes] %s %s main\n" "$REPO_BASE" "$REPO_SUITE" > "$SOURCES_LIST"
            chmod 644 "$SOURCES_LIST"
            ;;
        repo_update)
            log "$((step++)). Updating APT repository to suite '$REPO_SUITE'..."
            printf "deb [trusted=yes] %s %s main\n" "$REPO_BASE" "$REPO_SUITE" > "$SOURCES_LIST"
            chmod 644 "$SOURCES_LIST"
            ;;
        upgrade)
            log "$((step++)). APT repository already correct (suite: $REPO_SUITE)."
            ;;
    esac

    log "$((step++)). Updating package lists..."
    builtin command apt-get update -q >> "$LOG_FILE" 2>&1

    if [[ "$mode" == "fresh" ]]; then
        log "$((step++)). Installing open-iscsi and $PACKAGE_NAME..."
        builtin command apt-get install -y -q open-iscsi "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1
    else
        log "$((step++)). Upgrading $PACKAGE_NAME..."
        builtin command apt-get install -y -q --only-upgrade "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1
    fi

    log "$((step++)). Restarting PVE services ($RESTARTED_SERVICES)..."
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
}

# Install the plugin + GUI straight from the local repo copy (no APT repo, no .deb).
# Note: a later `apt upgrade` of the .deb package, if also installed, overwrites these files.
function install_local()
{
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would install $LOCAL_DIR/NimbleStoragePlugin.pm -> $PM_TARGET"
        log "DRY-RUN: would install $LOCAL_DIR/www/NimbleEdit.js -> $GUI_JS and add its tag to $GUI_TPL"
        log "DRY-RUN: would restart PVE services: systemctl try-reload-or-restart $RESTARTED_SERVICES"
        return
    fi

    head -n 1 "$LOCAL_DIR/NimbleStoragePlugin.pm" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin' \
        || fail "$LOCAL_DIR/NimbleStoragePlugin.pm does not look like the Nimble plugin"

    log "1. Installing open-iscsi..."
    builtin command apt-get install -y -q open-iscsi >> "$LOG_FILE" 2>&1

    log "2. Installing plugin from $LOCAL_DIR..."
    install -d -m 755 "$(dirname "$PM_TARGET")"
    install -m 644 "$LOCAL_DIR/NimbleStoragePlugin.pm" "$PM_TARGET"

    log "3. Installing GUI (NimbleEdit.js)..."
    bash "$LOCAL_DIR/scripts/install-nimble-gui.sh" --js "$LOCAL_DIR/www/NimbleEdit.js" --no-restart >> "$LOG_FILE" 2>&1

    log "4. Restarting PVE services ($RESTARTED_SERVICES)..."
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
}

# Copy the local repo files to a remote node over SSH and install them there.
function push_local_to_node()
{
    local ip="$1" tmp
    local -a ssh_opts=( -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new )

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would scp local copy to root@$ip and install it there"
        return
    fi

    tmp=$(builtin command /usr/bin/ssh "${ssh_opts[@]}" "root@${ip}" mktemp -d) || fail "cannot ssh to root@$ip"
    builtin command /usr/bin/scp "${ssh_opts[@]}" -q \
        "$LOCAL_DIR/NimbleStoragePlugin.pm" "$LOCAL_DIR/www/NimbleEdit.js" \
        "$LOCAL_DIR/scripts/install-nimble-gui.sh" "root@${ip}:${tmp}/" || fail "scp to root@$ip failed"
    builtin command /usr/bin/ssh "${ssh_opts[@]}" "root@${ip}" "set -e
        apt-get install -y -q open-iscsi >/dev/null
        install -d -m 755 $(dirname "$PM_TARGET")
        install -m 644 $tmp/NimbleStoragePlugin.pm $PM_TARGET
        bash $tmp/install-nimble-gui.sh --js $tmp/NimbleEdit.js --no-restart
        rm -rf $tmp
        systemctl try-reload-or-restart $RESTARTED_SERVICES"
}

function show_status()
{
    local ver svc
    ver=$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true)
    log "Package : ${ver:-not installed (.deb)}"
    log "Plugin  : $([ -f "$PM_TARGET" ] && echo "present ($PM_TARGET)" || echo MISSING)"
    log "GUI JS  : $([ -f "$GUI_JS" ] && echo "present ($GUI_JS)" || echo MISSING)"
    log "GUI tag : $(grep -qF NimbleEdit.js "$GUI_TPL" 2>/dev/null && echo "present in $GUI_TPL" || echo "MISSING from $GUI_TPL")"
    for svc in $RESTARTED_SERVICES; do
        log "Service : $svc $(systemctl is-active "$svc" 2>/dev/null || true)"
    done
}

# Remove plugin + GUI from this node (works for both .deb and local-copy installs)
function uninstall_plugin()
{
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would remove $PACKAGE_NAME, $PM_TARGET, $GUI_JS and its tag in $GUI_TPL"
        return
    fi
    if [[ "${YES:-0}" -ne 1 && -t 0 ]]; then
        read -r -p "Remove the Nimble plugin and GUI from this node? (y/n): " choice
        [[ "$choice" == "y" ]] || { log "Aborted."; exit 1; }
    fi
    if dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null | grep -q "install ok installed"; then
        builtin command apt-get remove -y -q "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1
    fi
    rm -f "$PM_TARGET" "$GUI_JS" /etc/apt/apt.conf.d/99nimble-gui /usr/local/sbin/nimble-gui-install
    [[ -f "$GUI_TPL" ]] && sed -i '/NimbleEdit\.js/d' "$GUI_TPL"
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
    log "Plugin and GUI removed. Storage entries in /etc/pve/storage.cfg were left untouched."
}

# Interactive menu: sets ACTION / SOURCE / ALL_NODES / INSTALL_VERSION, or exits
function show_menu()
{
    local choice local_dir
    local_dir=$(find_local_dir || true)
    valid_local_dir "$local_dir" || local_dir=""

    cat <<EOF
----------------------------------------------------------
  1) Install / upgrade from GitHub (APT repo)
  2) Install a specific release from GitHub
  3) Install from local copy   ${local_dir:-(not available: not run from a repo checkout)}
  4) Install on ALL cluster nodes from GitHub
  5) Install on ALL cluster nodes from local copy
  6) Show status
  7) Uninstall
  0) Quit
EOF
    read -r -p "Select an option: " choice < /dev/tty
    case "$choice" in
        1) SOURCE=remote ;;
        2) SOURCE=remote
           read -r -p "Release version (X.Y.Z): " INSTALL_VERSION < /dev/tty
           [[ -n "$INSTALL_VERSION" ]] || fail "No version given" ;;
        3) use_local ;;
        4) SOURCE=remote; ALL_NODES=1 ;;
        5) ALL_NODES=1; use_local ;;
        6) ACTION=status ;;
        7) ACTION=uninstall ;;
        0) exit 0 ;;
        *) fail "Invalid choice: $choice" ;;
    esac
}

function install_from_github_deb()
{
    local ver="$INSTALL_VERSION"
    local deb_name="${PACKAGE_NAME}_${ver}-1_all.deb"
    local deb_url="${GITHUB_RELEASES_BASE}/v${ver}/${deb_name}"
    local deb_tmp
    deb_tmp=$(mktemp -t "pve-nimble-plugin-${deb_name}.XXXXXX")

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would install open-iscsi: apt-get install -y -q open-iscsi"
        log "DRY-RUN: would download $deb_url"
        log "DRY-RUN: would install: dpkg -i $deb_name && apt-get install -f -y"
        log "DRY-RUN: would restart PVE services: systemctl try-reload-or-restart $RESTARTED_SERVICES"
        return
    fi

    log "1. Installing open-iscsi..."
    builtin command apt-get install -y -q open-iscsi >> "$LOG_FILE" 2>&1

    log "2. Downloading $deb_name from GitHub releases..."
    if ! builtin command /usr/bin/curl -fsSL -o "$deb_tmp" "$deb_url"; then
        rm -f "$deb_tmp"
        fail "Failed to download $deb_url (check version and network)"
    fi

    log "3. Installing $PACKAGE_NAME..."
    if ! dpkg -i "$deb_tmp"; then
        apt-get install -f -y -q >> "$LOG_FILE" 2>&1 || true
    fi
    rm -f "$deb_tmp"

    log "4. Restarting PVE services ($RESTARTED_SERVICES)..."
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
}

##########################################################
# post_install
##########################################################
function post_install()
{
    if [ -z "$REMOTE_NODE" ]; then
        log ""
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log "PVE Nimble Storage Plugin dry run complete. No changes were made."
        else
            if [ ! -f "$GUI_JS" ] || ! grep -qF NimbleEdit.js "$GUI_TPL" 2>/dev/null; then
                log "WARNING: GUI not fully installed (NimbleEdit.js or its tag in $GUI_TPL is missing)."
                log "         Run scripts/install-nimble-gui.sh on this node, then hard-refresh the browser."
            fi
            log "PVE Nimble Storage Plugin installation complete."
        fi
    fi
}

function prepare()
{
    LOG_FILE=/dev/null
    VERBOSE=0
    LOG_FILE_SET=0
    YES=0
    ALL_NODES=0
    DRY_RUN=0
    INSTALL_VERSION=""
    SOURCE=auto
    LOCAL_DIR=""
    ACTION=install

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--codename)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                REPO_SUITE="$2"
                REPO_SUITE_SET=1
                shift 2
                ;;
            -V|--version)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                INSTALL_VERSION="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -y|--yes)
                YES=1
                shift
                ;;
            -a|--all-nodes)
                ALL_NODES=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -L|--local)
                SOURCE=local
                shift
                ;;
            -g|--github)
                SOURCE=remote
                shift
                ;;
            --local-dir)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                SOURCE=local
                LOCAL_DIR="$2"
                shift 2
                ;;
            -s|--status)
                ACTION=status
                shift
                ;;
            -u|--uninstall)
                ACTION=uninstall
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -l|--log-file)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                LOG_FILE="$2"
                LOG_FILE_SET=1
                shift 2
                ;;
            --installer-url)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                INSTALLER_URL=$2
                shift 2
                ;;
            -X)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                REMOTE_NODE=$2
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                fail "Unknown option: $1"
                ;;
            *)
                log "Ignoring positional argument: $1"
                shift
                ;;
        esac
    done

    if [[ "$VERBOSE" -eq 1 && "${LOG_FILE_SET}" -eq 0 ]]; then
        LOG_FILE=/dev/stderr
    fi
}

##########################################################
# Verify and install the PVE Nimble Storage Plugin
##########################################################
install_pve_plugin()
{
    local argc=$#
    prepare "$@"
    issue
    preflight
    [[ "$SOURCE" == local ]] && use_local
    if [[ "$argc" -eq 0 && -t 1 && -r /dev/tty ]]; then
        show_menu
    fi
    if [[ "$SOURCE" == auto ]]; then
        if [[ -z "$INSTALL_VERSION" ]] && valid_local_dir "$(find_local_dir || true)"; then
            use_local
        else
            SOURCE=remote
        fi
    fi
    case "$ACTION" in
        status)
            show_status
            return
            ;;
        uninstall)
            uninstall_plugin
            return
            ;;
    esac
    if [[ "${ALL_NODES:-0}" -eq 1 ]]; then
        install_on_all_nodes
    else
        install_software
    fi
    post_install
}

##########################################################
# execute
##########################################################
install_pve_plugin "$@"
