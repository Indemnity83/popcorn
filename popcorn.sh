#!/usr/bin/env bash
# Popcorn: pause your Forge sites and wait for the dust to settle.
# Save this entire file as popcorn.sh; no companion files required.
# Requires Python 3, OpenSSL, systemd and standard Ubuntu administration tools.
# Python is embedded below; neither PHP nor a working Nginx binary is needed.
#
# Start here:
#   sudo bash popcorn.sh dry-run
#   sudo bash popcorn.sh install    # only if /usr/bin/caddy is missing
#   sudo bash popcorn.sh deploy
#   sudo bash popcorn.sh verify
#   sudo bash popcorn.sh status
#   sudo bash popcorn.sh rollback RELEASE_ID
#   sudo bash popcorn.sh stop
#   sudo bash popcorn.sh teardown --dry-run
#   sudo bash popcorn.sh teardown
#
# Stop Nginx yourself before deploy; start it yourself after stopping Popcorn.
# Never stops/starts/reloads Nginx or PHP. Never edits existing Nginx/Caddy configs.
# Stops on occupied ports, unsupported/ambiguous config, or invalid TLS coverage.
# New releases and root-only backups live under /etc/popcorn.
# Maintenance is not enabled at boot; review existing services before rebooting.
# Certificate copies are not renewed: redeploy after Forge certificate renewal.
# Public reachability still needs a remote curl check (see --help).
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]:-$0}")"
ROOT=/etc/popcorn
UNIT=/etc/systemd/system/popcorn.service
STATE=/var/lib/popcorn
SERVICE=popcorn.service
TMP=''
MASKED=0
TRANSACTION=0
OLD=''
WAS_ACTIVE=0
UNIT_NEW=0

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null || die "Required command missing: $1"; }
root() { [[ $EUID == 0 ]] || die 'Run with sudo/root (certificate keys require root).'; }
active() { systemctl is-active --quiet "$SERVICE"; }
point_to() {
    local dest=$1
    ln -s -- "$dest" "$ROOT/current.next"
    mv -Tf -- "$ROOT/current.next" "$ROOT/current"
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if (( TRANSACTION )); then
        log 'Activation failed/interrupted; restoring the prior maintenance state.'
        systemctl stop "$SERVICE" || true
        rm -f -- "$ROOT/current.next"
        if [[ -n $OLD ]]; then
            point_to "$OLD" || log 'CRITICAL: could not restore current symlink; consult backup.'
        else
            rm -f -- "$ROOT/current"
        fi
        if (( UNIT_NEW )); then
            rm -f -- "$UNIT"
            systemctl daemon-reload || true
        fi
        if (( WAS_ACTIVE )); then
            systemctl start "$SERVICE" || log 'CRITICAL: previous maintenance release could not restart; inspect journal.'
        fi
    fi
    if (( MASKED )); then
        rm -f -- /run/systemd/system/caddy.service
        systemctl daemon-reload || true
    fi
    [[ -z $TMP ]] || rm -rf -- "$TMP"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'EOF'
Usage: sudo bash popcorn.sh COMMAND [OPTIONS]
  dry-run [--enabled DIR] [--prefix DIR] [--minimum-valid-seconds N]
      Show discovered sites, certificate checks, readiness and next commands.
      No service changes or persistent configuration writes.
  install
      Install Ubuntu's configured APT candidate for Caddy, with package auto-start masked.
  deploy [same options as dry-run]
      Back up, create and validate a new release, start ONLY popcorn, probe all names.
  status
      Show maintenance state and available release IDs.
  verify [--ip ADDRESS]
      Probe every current hostname using curl --resolve (TLS trust/hostname checks enabled).
  rollback RELEASE_ID
      Validate and activate an existing release. Never changes Nginx or stock Caddy.
  stop
      Stop the holding pages and keep all Popcorn files/backups for reuse.
  teardown [--dry-run]
      Stop/remove the managed service, all releases, certificate copies, backups
      and maintenance runtime data. --dry-run lists removals without stopping it.
      Leaves Caddy installed, the script itself and shared journal history intact.

Defaults: /etc/nginx/sites-enabled, Nginx include prefix /etc/nginx,
certificate expiry warning threshold 86400 seconds. ASCII concrete DNS names only.
This utility never stops, starts or reloads Nginx/PHP/stock Caddy.
install disables boot enablement of the newly installed stock Caddy service.
Maintenance is started for this boot only; no services are enabled at boot.

Safety and discovery:
  Every file/symlink in the enabled directory is scanned. Confirm nginx.conf
  includes it; extra conf.d sites outside that directory are not discovered.
  Includes use --prefix for relative paths. Review the discovered site list.
  HTTP redirects are replaced with 503; unnamed/default blocks are skipped.
  Unknown HTTP hosts return 404. Unmatched HTTPS requests return 404 if TLS
  completes; SNI without a matching loaded certificate normally fails TLS.
  HTTP-only names stay HTTP-only; no aliases or certificates are invented.
  Leading-dot names automatically use the base domain and matching concrete
  DNS names from their configured certificate. Wildcards are not enumerated.
  Optional: --expand-name .domain=host1,host2 overrides that automatic list.
  Other regex/wildcard/variable server names, private/nonstandard listeners,
  inherited/multiple certificate pairs and conflicting TLS mappings are refused.
  Expired/unusable certificates disable HTTPS for that site; HTTP remains.
  Valid certificates nearing expiry warn without blocking other sites. Wildcard certificates for explicit names are supported.
  Private-CA/self-signed chains require prior trust in the system trust store.
  APT install uses configured repositories, no apt update or requested upgrades.
  It refuses an existing Caddy config/unit without a working /usr/bin/caddy.
  No original Forge key permissions are changed; protected copies are used.

Verification:
  Validation/check logs: /etc/popcorn/logs/ (routine warnings are saved here).
  sudo journalctl -u popcorn.service -n 100 --no-pager
  sudo ss -ltnp '( sport = :80 or sport = :443 )'
  curl --noproxy '*' --resolve HOST:443:SERVER_IP -D - -o /dev/null https://HOST/
  Replace HOST and SERVER_IP; repeat externally for every hostname and HTTP :80.
  Expect 503, Retry-After: 600, Cache-Control: no-store; do not use curl -k.
  Also test the normal public URL if a CDN/proxy fronts the site.

Rollback and recovery:
  status lists complete release IDs. rollback ID validates its copied certs,
  activates that release and probes it; failed activation restores prior state.
  The stop command stops ONLY maintenance; return Nginx/PHP to service deliberately
  after security patches and production validation. Nothing starts them here.
  Backups: /etc/popcorn/backups/ID/{configuration.tar,state.txt};
  deployment also archives resolved includes in included-sources.tar.
  Backups contain secrets: inspect before restoring, never blindly untar over /.
  Normal errors and SIGINT/SIGTERM trigger recovery. After power loss/SIGKILL,
  inspect current, current.next, backup state and the journal before rollback.
  A stale current.next causes refusal; inspect and remove only that stale link.
  Retained releases contain key copies; remove obsolete releases deliberately.
  teardown permanently deletes ALL managed backups and certificate copies.
  Use teardown --dry-run to inspect the scope first. It never starts production
  services, uninstalls Caddy, or deletes original Forge/Nginx certificate files.

Taking sites offline and returning them to service (manual handoff):
  Stop Nginx deliberately before deploy: sudo systemctl stop nginx.service
  Popcorn does not stop PHP-FPM or queue workers; manage those separately.
  After patches, restore the PHP-FPM units actually used by your sites and
  validate production configuration before removing the maintenance page.
  Stop Popcorn with stop, or remove it using teardown. Then check
  TCP 80/443 and UDP 443 are free before starting Nginx again:
    sudo nginx -t && sudo systemctl start nginx.service
    sudo systemctl status nginx.service --no-pager
  popcorn.service runs Caddy; caddy.service is a separate stock service.
  If you used the stock service for maintenance too, stop/disable it deliberately
  before returning the ports to Nginx. Neither command starts production for you.
EOF
}

unit_text() {
    cat <<'EOF'
# Managed by popcorn v1; no boot enablement by design.
[Unit]
Description=Forge temporary static maintenance server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --config /etc/popcorn/current/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=3s
TimeoutStopSec=15s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/popcorn
StateDirectory=popcorn
Environment=HOME=/var/lib/popcorn
Environment=XDG_DATA_HOME=/var/lib/popcorn/data
Environment=XDG_CONFIG_HOME=/var/lib/popcorn/config
UMask=0027
EOF
}

check_platform() {
    [[ -r /etc/os-release ]] || die 'Ubuntu required.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || die 'This deployment entry point supports Ubuntu only.'
    [[ -d /run/systemd/system ]] || die 'A running systemd host is required.'
    for cmd in python3 openssl systemctl flock ss tar runuser curl; do need "$cmd"; done
}

check_layout() {
    # Never adopt an existing unrelated directory or symlink.
    if [[ -e $ROOT || -L $ROOT ]]; then
        [[ -d $ROOT && ! -L $ROOT && -f $ROOT/managed-v1 ]] || die "$ROOT exists without our marker; refusing to adopt."
        [[ $(stat -c %u "$ROOT") == 0 && $(stat -c %a "$ROOT") == 750 ]] || die "$ROOT must be root-owned mode 0750."
    fi
    if [[ -e $UNIT || -L $UNIT ]]; then
        if [[ ! -f $UNIT || -L $UNIT ]] || ! cmp -s "$UNIT" <(unit_text); then
            die "Existing $UNIT differs; refusing to overwrite."
        fi
    elif systemctl cat "$SERVICE" >/dev/null 2>&1; then
        die 'A maintenance unit exists elsewhere; refusing to shadow it.'
    fi
    [[ -z $(systemctl show "$SERVICE" -p DropInPaths --value 2>/dev/null) ]] || die 'Unexpected systemd drop-ins; refusing.'
    [[ ! -d /etc/systemd/system/popcorn.service.d ]] || die 'Unexpected maintenance service overrides; refusing.'
    [[ ! -e /run/systemd/system/popcorn.service && ! -d /run/systemd/system/popcorn.service.d ]] || die 'Unexpected runtime service overrides; refusing.'
    [[ ! -e $ROOT/current.next && ! -L $ROOT/current.next ]] || die 'Stale current.next exists; inspect it first.'
    local path
    for path in "$ROOT/releases" "$ROOT/backups"; do
        if [[ -e $path || -L $path ]]; then
            [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 ]] || die "Unsafe managed subdirectory: $path"
        fi
    done
    if [[ -e $ROOT/current || -L $ROOT/current ]]; then
        [[ -L $ROOT/current ]] || die 'current is not a symlink.'
        OLD=$(readlink -f "$ROOT/current")
        [[ $OLD =~ ^/etc/popcorn/releases/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$ && -f $OLD/complete ]] || die 'Invalid current release link.'
    fi
    if active; then
        WAS_ACTIVE=1
        [[ -n $OLD && -f $UNIT ]] || die 'Active maintenance service is not managed by this utility.'
    fi
}

next_command() {
    # Shell-quote the script location and arguments so displayed commands are reusable.
    printf '  sudo bash ' >&2
    printf '%q ' "$SELF" "$@" >&2
    printf '\n' >&2
}

caddy_present() { [[ -x /usr/bin/caddy ]]; }
caddy_account_ready() { getent passwd caddy >/dev/null && getent group caddy >/dev/null; }

readiness_report() {
    local discovered=$1
    shift
    local ready=1 missing=0 account_bad=0 nginx_up=0 stock_up=0
    local own_pid='' nginx_pid='' stock_pid='' listeners='' udp='' line
    local other=0 ports_bad=0 layout_error=''
    if ! caddy_present; then
        missing=1; ready=0
        log 'Caddy is not installed.'
    elif ! caddy_account_ready; then
        account_bad=1; ready=0
        log 'Caddy is installed, but its service account is missing.'
    else
        log 'Caddy is installed and ready.'
    fi
    if systemctl is-active --quiet nginx.service; then
        nginx_up=1; ready=0
        nginx_pid=$(systemctl show nginx.service -p MainPID --value)
        log 'Nginx is still running.'
    else
        log 'Nginx is stopped.'
    fi
    if systemctl is-active --quiet caddy.service; then
        stock_up=1; ready=0
        stock_pid=$(systemctl show caddy.service -p MainPID --value)
        log 'An existing Caddy service is running.'
    fi
    if active; then
        own_pid=$(systemctl show "$SERVICE" -p MainPID --value)
        log 'Popcorn is already running.'
    fi
    if listeners=$(ss -H -ltnp '( sport = :80 or sport = :443 )') &&
       udp=$(ss -H -lunp 'sport = :443'); then
        listeners+=$'\n'"$udp"
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            if [[ -n $own_pid && $own_pid != 0 && $line == *"pid=$own_pid,"* ]] ||
               [[ -n $nginx_pid && $nginx_pid != 0 && $line == *"pid=$nginx_pid,"* ]] ||
               [[ -n $stock_pid && $stock_pid != 0 && $line == *"pid=$stock_pid,"* ]]; then
                continue
            fi
            other=1; ready=0
        done <<< "$listeners"
    else
        ports_bad=1; ready=0
    fi
    if ! layout_error=$( (trap - EXIT; check_layout) 2>&1); then ready=0; fi
    log ''
    if [[ $discovered == 1 ]]; then
        discovery summary "$TMP/inventory.json" >&2
    else
        ready=0
        log 'Could not list the sites. See the discovery error above.'
    fi
    log ''
    if (( ready )); then
        log 'Ready. Start maintenance with:'
        next_command deploy "$@"
    else
        log 'Not ready yet:'
        if (( missing )); then
            log 'Install Caddy:'
            next_command install
        fi
        if (( account_bad )); then log 'Repair the Caddy package/service account before deploying.'; fi
        if (( nginx_up )); then
            log 'When ready to take the sites offline, stop Nginx:'
            log '  sudo systemctl stop nginx.service'
        fi
        if (( stock_up )); then
            log 'When ready to replace the existing Caddy maintenance service, stop it:'
            log '  sudo systemctl stop caddy.service'
        fi
        if (( other || ports_bad )); then
            log 'Check the other process using web ports, or resolve the listener-check error:'
            log "  sudo ss -ltnp '( sport = :80 or sport = :443 )'"
            log "  sudo ss -lunp 'sport = :443'"
        fi
        if [[ -n $layout_error ]]; then log "$layout_error"; fi
        if [[ $discovered != 1 ]]; then log 'Fix the site discovery error above.'; fi
        log 'Then check again:'
        next_command dry-run "$@"
    fi
    log 'Dry-run only; nothing changed.'
}

return_guidance() {
    log ''
    log 'To bring application sites back, restore patched PHP-FPM if needed, then run:'
    log '  sudo nginx -t && sudo systemctl start nginx.service'
}

stop_popcorn() {
    check_layout
    if [[ -f $UNIT ]]; then systemctl stop "$SERVICE"; fi
    log 'Popcorn stopped. Configuration and backups kept for reuse.'
    return_guidance
}

teardown() {
    local preview=0 have_root=0 have_unit=0 path mounts mount enablement disable_error
    case $# in
        0) ;;
        1) [[ $1 == --dry-run ]] || die 'teardown accepts only --dry-run.'; preview=1 ;;
        *) die 'teardown accepts only --dry-run.' ;;
    esac
    # Use fixed namespaces and prove ownership before any service action or deletion.
    # Unlike deployment checks, permit incomplete releases/dangling current links:
    # those are precisely the leftovers teardown must be able to clean up.
    [[ $ROOT == /etc/popcorn &&
       $UNIT == /etc/systemd/system/popcorn.service &&
       $STATE == /var/lib/popcorn &&
       $SERVICE == popcorn.service ]] || die 'Unexpected teardown paths.'
    if [[ -e $ROOT || -L $ROOT ]]; then
        [[ -d $ROOT && ! -L $ROOT && $(stat -c %u "$ROOT") == 0 &&
           $(stat -c %a "$ROOT") == 750 ]] || die 'Unrecognized maintenance directory; refusing teardown.'
        [[ -f $ROOT/managed-v1 && ! -L $ROOT/managed-v1 &&
           $(stat -c %u "$ROOT/managed-v1") == 0 ]] || die 'Missing/unsafe ownership marker; refusing teardown.'
        cmp -s "$ROOT/managed-v1" <(printf 'popcorn v1\n') || die 'Unrecognized ownership marker; refusing teardown.'
        have_root=1
    fi
    if [[ -e $UNIT || -L $UNIT ]]; then
        [[ -f $UNIT && ! -L $UNIT && $(stat -c %u "$UNIT") == 0 ]] || die 'Unsafe maintenance unit; refusing teardown.'
        cmp -s "$UNIT" <(unit_text) || die 'Maintenance unit was modified; refusing to remove it.'
        have_unit=1
    elif systemctl cat "$SERVICE" >/dev/null 2>&1; then
        die 'A maintenance unit exists elsewhere; refusing teardown.'
    fi
    [[ -z $(systemctl show "$SERVICE" -p DropInPaths --value 2>/dev/null) ]] || die 'Maintenance service has overrides; inspect them before teardown.'
    for path in /etc/systemd/system/popcorn.service.d \
                /run/systemd/system/popcorn.service \
                /run/systemd/system/popcorn.service.d; do
        [[ ! -e $path && ! -L $path ]] || die "Unexpected override: $path; refusing teardown."
    done
    if active && (( ! have_unit )); then
        die 'Active service has no verified managed unit; refusing teardown.'
    fi
    if [[ -e $STATE || -L $STATE ]]; then
        (( have_root || have_unit )) || die 'Orphaned state without ownership evidence; refusing deletion.'
        [[ -d $STATE && ! -L $STATE ]] || die 'Maintenance state is not a normal directory; refusing deletion.'
    fi
    # Do not traverse bind mounts or other mounted filesystems inside managed paths.
    need findmnt
    mounts=$(findmnt -rn -o TARGET) || die 'Cannot inspect mount points; refusing teardown.'
    while IFS= read -r mount; do
        for path in "$ROOT" "$STATE"; do
            [[ $mount != "$path" && $mount != "$path/"* ]] || die "Mount under $path; unmount it explicitly before teardown."
        done
    done <<< "$mounts"
    log "Teardown scope: $SERVICE, $UNIT, $ROOT (ALL releases/keys/backups), $STATE"
    log 'Caddy package, original Forge/Nginx files, this script and shared journal history are retained.'
    if (( preview )); then
        log 'Dry-run only: no service was stopped and nothing was deleted.'
        return 0
    fi
    if (( have_unit )); then
        systemctl stop "$SERVICE"
        active && die 'Maintenance service is still active; refusing deletion.'
        # This unit has no [Install] section and is normally static. Only
        # disable it if someone separately created actual enablement links.
        enablement=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)
        case $enablement in
            enabled|enabled-runtime)
                if ! disable_error=$(systemctl disable "$SERVICE" 2>&1); then
                    log "$disable_error"
                    die 'Could not remove maintenance service enablement; files were kept.'
                fi
                ;;
        esac
        # A stopped or unloaded unit has no failed state to clear.
        if systemctl is-failed --quiet "$SERVICE"; then
            systemctl reset-failed "$SERVICE"
        fi
    fi
    # Leave the ownership evidence until its associated data has been removed.
    # Never follow symlinks; --one-file-system adds protection against mount races.
    if [[ -d $STATE ]]; then rm -rf --one-file-system -- "$STATE"; fi
    if (( have_root )); then rm -rf --one-file-system -- "$ROOT"; fi
    if (( have_unit )); then rm -f -- "$UNIT"; fi
    systemctl daemon-reload
    log 'Popcorn removed. Generated files, copied keys and backups deleted.'
    return_guidance
}

ports_available() {
    local pid='' line listeners
    listeners=$(ss -H -ltnp '( sport = :80 or sport = :443 )') || die 'Cannot inspect TCP listeners.'
    listeners+=$'\n'$(ss -H -lunp 'sport = :443') || die 'Cannot inspect UDP listeners.'
    if active; then pid=$(systemctl show "$SERVICE" -p MainPID --value); fi
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        if [[ -z $pid || $pid == 0 || $line != *"pid=$pid,"* ]]; then
            die "Port 80/443 is in use; no service was stopped: $line"
        fi
    done <<< "$listeners"
    systemctl is-active --quiet nginx.service && die 'Nginx is active; arrange the handoff explicitly before deployment.'
    systemctl is-active --quiet caddy.service && die 'Stock caddy.service is active; arrange the handoff explicitly before deployment.'
    return 0
}

init_layout() {
    if [[ ! -d $ROOT ]]; then
        install -d -o root -g caddy -m 0750 "$ROOT"
        printf 'popcorn v1\n' > "$ROOT/managed-v1"
    fi
    install -d -o root -g caddy -m 0750 "$ROOT/releases"
    install -d -o root -g root -m 0700 "$ROOT/backups"
}

backup() {
    local backup_id=$1 path
    [[ ! -e $ROOT/backups/$backup_id && ! -L $ROOT/backups/$backup_id ]] || die 'Backup ID already exists; refusing to overwrite.'
    install -d -o root -g root -m 0700 "$ROOT/backups/$backup_id"
    local paths=()
    for path in etc/nginx etc/caddy etc/systemd/system/popcorn.service etc/popcorn/current; do
        [[ ! -e /$path && ! -L /$path ]] || paths+=("$path")
    done
    if ((${#paths[@]})); then tar -C / -cpf "$ROOT/backups/$backup_id/configuration.tar" -- "${paths[@]}"; fi
    {
        printf 'previous_release=%s\nmaintenance_was_active=%s\n' "$OLD" "$WAS_ACTIVE"
        systemctl show nginx.service caddy.service "$SERVICE" -p Id -p ActiveState -p UnitFileState ||
            printf 'Some units were unavailable (normal before first deployment).\n'
    } > "$ROOT/backups/$backup_id/state.txt"
    # Included files outside /etc/nginx are captured separately during deploy.
}

new_log() {
    install -d -m 0700 "$ROOT/logs"
    mktemp "$ROOT/logs/$1.XXXXXXXX"
}

validate() {
    local release=$1 logfile
    logfile=$(new_log validation)
    log ''
    log 'Checking Caddy configuration...'
    if runuser -u caddy -- /usr/bin/caddy validate --config "$release/Caddyfile" --adapter caddyfile > "$logfile" 2>&1; then
        log '  Configuration OK.'
    else
        log "  Configuration check failed. Full log: $logfile"
        tail -n 20 "$logfile" >&2
        die 'Caddy validation failed; the current service was not changed.'
    fi
}

activate() {
    local release=$1
    TRANSACTION=1
    if [[ ! -f $UNIT ]]; then
        UNIT_NEW=1
        unit_text > "$UNIT"
        chmod 0644 "$UNIT"
        systemctl daemon-reload
    fi
    point_to "$release"
    systemctl restart "$SERVICE"
    # Restart=on-failure is not evidence that startup succeeded. Probe boundedly.
    local ok=0 attempt logfile
    logfile=$(new_log verification)
    log 'Checking maintenance pages...'
    for attempt in 1 2 3; do
        if discovery probe "$release/inventory.json" > "$logfile" 2>&1; then ok=1; break; fi
        if (( attempt < 3 )); then sleep 1; fi
    done
    if (( ! ok )); then
        log "Maintenance page checks failed. Log: $logfile"
        cat "$logfile" >&2
        die 'Post-activation probes failed.'
    fi
    active || die 'Maintenance service is not active after verification.'
    cat "$logfile" >&2
    TRANSACTION=0
    log ''
    log '🍿 Maintenance pages are up for the sites/endpoints listed above. Go get your popcorn!'
    discovery limitations "$release/inventory.json" >&2
    log ''
    log "When you're ready to return, choose one:"
    log 'Stop Popcorn and keep its files for reuse:'
    next_command stop
    log 'Or remove Popcorn and all its generated files/backups:'
    next_command teardown
    return_guidance
}

discovery() {
    python3 - "$@" <<'POPCORN_EMBEDDED_PYTHON'
#!/usr/bin/env python3
"""Conservative, offline Forge Nginx inventory and Caddy release builder."""
import argparse
import datetime as dt
import glob
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class Invalid(ValueError):
    pass


def run(*args):
    p = subprocess.run(args, input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise Invalid(f'{args[0]} {args[1]} failed (invalid/unreadable certificate or unencrypted key required)')
    return p.stdout


def lex(text):
    # Tokenize without evaluating Nginx variables, shell text, or includes.
    out, word, quote, i = [], '', None, 0
    while i < len(text):
        c = text[i]
        if c == '\\':
            i += 1
            if i == len(text):
                raise Invalid('Trailing escape')
            word += text[i]
        elif quote:
            if c == quote:
                quote = None
            else:
                word += c
        elif c in "\"'":
            quote = c
        elif c == '#':
            while i < len(text) and text[i] != '\n':
                i += 1
            continue
        elif c.isspace() or c in '{};':
            if word:
                out.append(word)
                word = ''
            if c in '{};':
                out.append(c)
        else:
            word += c
        i += 1
    if quote:
        raise Invalid('Unclosed quote')
    if word:
        out.append(word)
    return out


class Parser:
    def __init__(self, prefix):
        self.prefix = Path(prefix)
        self.sources = set()

    def file(self, path, stack=()):
        path = Path(path).resolve(strict=True)
        if path in stack or len(stack) > 32:
            raise Invalid(f'Include loop/depth limit: {path}')
        self.sources.add(str(path))
        ts = lex(path.read_text())
        pos = 0

        def block(nested=False):
            nonlocal pos
            nodes = []
            while pos < len(ts):
                if ts[pos] == '}':
                    if not nested:
                        raise Invalid(f'Unexpected closing brace: {path}')
                    pos += 1
                    return nodes
                words = []
                while pos < len(ts) and ts[pos] not in '{};':
                    words.append(ts[pos])
                    pos += 1
                if not words or pos == len(ts) or ts[pos] == '}':
                    raise Invalid(f'Incomplete directive: {path}')
                end = ts[pos]
                pos += 1
                children = block(True) if end == '{' else None
                if words[0] == 'include':
                    if children is not None or len(words) != 2 or '$' in words[1]:
                        raise Invalid(f'Unsupported include: {path}')
                    pattern = Path(words[1])
                    if not pattern.is_absolute():
                        pattern = self.prefix / pattern
                    matches = sorted(glob.glob(str(pattern)))
                    if not matches and not glob.has_magic(str(pattern)):
                        raise Invalid(f'Missing include {pattern}')
                    for match in matches:
                        nodes.extend(self.file(match, (*stack, path)))
                else:
                    nodes.append((words, children, str(path)))
            if nested:
                raise Invalid(f'Unclosed block: {path}')
            return nodes
        return block()


def vals(nodes, directive):
    return [w[1:] for w, children, _ in nodes if w[0] == directive and children is None]


def hostname(value):
    value = value.lower()
    if value in ('_', ''):
        return None
    if len(value) > 253 or '.' not in value or not all(
        re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label)
        for label in value.split('.')
    ):
        raise Invalid(f'Unsupported server_name {value!r}: use explicit ASCII DNS names, no wildcards/regex/variables')
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise Invalid(f'IP server_name unsupported: {value}')


def certificate(cert, key, hosts, minimum):
    for path in (cert, key):
        if not Path(path).is_absolute() or '$' in path or not Path(path).is_file():
            raise Invalid(f'Certificate/key must be an existing absolute literal file: {path}')
    data = run('openssl', 'x509', '-in', cert, '-noout', '-dates', '-ext', 'subjectAltName').decode()
    if 'DNS:' not in data:
        raise Invalid(f'SAN DNS names required: {cert}')
    dates = dict(re.findall(r'(notBefore|notAfter)=(.*)', data))
    now = dt.datetime.now(dt.timezone.utc)
    warning = None
    for name in ('notBefore', 'notAfter'):
        parsed = dt.datetime.strptime(dates[name], '%b %d %H:%M:%S %Y %Z').replace(tzinfo=dt.timezone.utc)
        if name == 'notBefore' and parsed > now:
            raise Invalid(f'Certificate is not yet valid: {cert}')
        if name == 'notAfter':
            if parsed <= now:
                raise Invalid(f'Certificate has expired: {cert}')
            if parsed < now + dt.timedelta(seconds=minimum):
                warning = f'Certificate expires within {minimum} seconds: {cert}'
    public_cert = run('openssl', 'x509', '-in', cert, '-pubkey', '-noout')
    public_key = run('openssl', 'pkey', '-in', key, '-passin', 'pass:', '-pubout')
    if public_cert != public_key:
        raise Invalid(f'Certificate/key mismatch: {cert}')
    for host in hosts:
        checked = subprocess.run(['openssl', 'x509', '-in', cert, '-noout', '-checkhost', host],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Some OpenSSL versions return success even when the name does not match.
        if checked.returncode or 'does match certificate' not in checked.stdout.decode():
            raise Invalid(f'Certificate does not cover {host}: {cert}')
    return warning


def certificate_dns_names(cert):
    if not Path(cert).is_absolute() or '$' in cert or not Path(cert).is_file():
        raise Invalid(f'Certificate must be an existing absolute literal file: {cert}')
    data = run('openssl', 'x509', '-in', cert, '-noout', '-ext', 'subjectAltName').decode()
    return [name.lower() for name in re.findall(r'DNS:([^,\s]+)', data)]


def expansions(specs):
    result = {}
    for spec in specs:
        pattern, sep, names = spec.partition('=')
        pattern = pattern.lower()
        if not sep or not pattern.startswith('.') or not hostname(pattern[1:]):
            raise Invalid('Use --expand-name .example.com=example.com,www.example.com')
        if pattern in result:
            raise Invalid(f'Duplicate --expand-name mapping: {pattern}')
        hosts = names.split(',')
        if not names or any(not name or name != name.strip() for name in hosts):
            raise Invalid(f'Empty/invalid hostname list for {pattern}')
        concrete = []
        for value in hosts:
            host = hostname(value)
            if not host or not (host == pattern[1:] or host.endswith(pattern)):
                raise Invalid(f'Hostname {value!r} is outside Nginx pattern {pattern}')
            concrete.append(host)
        result[pattern] = sorted(set(concrete))
    return result


def inventory(enabled, prefix, minimum, expanded=None):
    parser = Parser(prefix)
    entries, notes = [], []
    expanded = expanded or {}
    used = set()
    files = sorted(Path(enabled).iterdir())
    if not files:
        raise Invalid(f'No enabled site files in {enabled}')
    for source in files:
        if not source.is_file():
            raise Invalid(f'Enabled entry is broken or not a file: {source}')
        nodes = parser.file(source)
        servers = [n for n in nodes if n[0] == ['server'] and n[1] is not None]
        if len(servers) != len(nodes):
            raise Invalid(f'Only server blocks/includes supported at site top level: {source}')
        for _, body, origin in servers:
            listens = vals(body, 'listen') or [['80']]
            tls = False
            for listen in listens:
                if not listen:
                    raise Invalid(f'Empty listen in {origin}')
                address = listen[0]
                # Accept only public all-interface 80/443 listeners; never silently expose a private bind.
                match = re.fullmatch(r'(?:(?:0\.0\.0\.0|\*|\[::\]):)?(80|443)', address)
                if not match or any(x not in ('ssl', 'http2', 'default_server', 'ipv6only=on', 'ipv6only=off') for x in listen[1:]):
                    raise Invalid(f'Unsupported/private listen {listen!r} in {origin}')
                port = match[1]
                if (port == '443') != ('ssl' in listen):
                    raise Invalid(f'Expected HTTP :80 or TLS :443 in {origin}')
                tls = tls or port == '443'
            raw_names = [v for group in vals(body, 'server_name') for v in group]
            if not any(value not in ('_', '') for value in raw_names):
                notes.append(f'Ignored unnamed/default {"TLS" if tls else "HTTP"} block in {origin}; no fallback certificate imported')
                continue
            certs, keys = vals(body, 'ssl_certificate'), vals(body, 'ssl_certificate_key')
            pair = None
            if tls:
                if len(certs) != 1 or len(keys) != 1 or len(certs[0]) != 1 or len(keys[0]) != 1:
                    raise Invalid(f'Exactly one explicit certificate/key pair required in {origin}; no inherited or multi-cert TLS')
                pair = (certs[0][0], keys[0][0])
            hosts = []
            tls_error = None
            automatic_patterns = []
            for raw in raw_names:
                value = raw.lower()
                if value.startswith('.'):
                    base = hostname(value[1:])
                    if not base:
                        raise Invalid(f'Invalid leading-dot server_name {value!r}')
                    if value in expanded:
                        if value not in used:
                            notes.append(f'Using custom hostname list for {value}')
                        used.add(value)
                        hosts.extend(expanded[value])
                    else:
                        automatic_patterns.append(value)
                        hosts.append(base)
                        if pair:
                            try:
                                sans = certificate_dns_names(pair[0])
                            except (Invalid, OSError, ValueError) as exc:
                                sans = []
                                tls_error = str(exc)
                            for san in sans:
                                if '*' not in san and (san == base or san.endswith(value)):
                                    host = hostname(san)
                                    if host:
                                        hosts.append(host)
                                elif '*' in san and san.endswith(value):
                                    note = 'Wildcard certificates: only discovered concrete hostnames are served; other subdomains receive no site page'
                                    if note not in notes:
                                        notes.append(note)
                else:
                    host = hostname(value)
                    if host:
                        hosts.append(host)
            hosts = sorted(set(hosts))
            if not hosts:
                notes.append(f'Ignored unnamed/default {"TLS" if tls else "HTTP"} block in {origin}; no fallback certificate imported')
                continue
            if tls:
                try:
                    warning = certificate(*pair, hosts, minimum)
                    if warning:
                        notes.append(f'Warning for {", ".join(hosts)}: {warning}')
                except (Invalid, OSError, ValueError) as exc:
                    tls_error = str(exc)
                if tls_error:
                    notes.append(f'HTTPS unavailable for {", ".join(hosts)}: {tls_error}')
                    pair = None
            if vals(body, 'ssl'):
                raise Invalid(f'Legacy ssl directive unsupported in {origin}')
            entries.append(dict(source=str(source), origin=origin, hosts=hosts, pair=pair, automatic_patterns=automatic_patterns, tls_error=tls_error))
    unused = set(expanded) - used
    if unused:
        raise Invalid(f'Unused --expand-name mapping(s): {", ".join(sorted(unused))}; check discovery scope/spelling')
    # HTTP redirect blocks can precede their TLS block. Reuse only concrete names
    # actually discovered in this inventory, and only inside that HTTP pattern.
    discovered_hosts = {host for entry in entries for host in entry['hosts']}
    for entry in entries:
        if not entry['pair']:
            for pattern in entry['automatic_patterns']:
                entry['hosts'] = sorted(set(entry['hosts']) | {
                    host for host in discovered_hosts if host == pattern[1:] or host.endswith(pattern)})
    # A name may appear in HTTP and HTTPS blocks. HTTPS wins; ambiguous TLS is rejected.
    mapping = {}
    for e in entries:
        for host in e['hosts']:
            if host in mapping and mapping[host]['pair'] and e['pair'] and mapping[host]['pair'] != e['pair']:
                raise Invalid(f'Conflicting HTTPS certificate mappings for {host}')
            if host not in mapping or e['pair'] or (not mapping[host]['pair'] and e['tls_error']):
                mapping[host] = e
    if not mapping:
        raise Invalid('No explicit DNS hosts discovered')
    groups = {}
    for host, e in sorted(mapping.items()):
        group = (e['source'], tuple(e['pair']) if e['pair'] else None, e['tls_error'])
        groups.setdefault(group, []).append(host)
    sites = [dict(source=source, hosts=hosts, certificate=pair[0] if pair else None,
                  key=pair[1] if pair else None, https_error=error) for (source, pair, error), hosts in groups.items()]
    for site in sites:
        if site['https_error']:
            notes.append(f"HTTPS unavailable for {', '.join(site['hosts'])}: {site['https_error']}")
    return dict(sites=sites, notes=notes, sources=sorted(parser.sources),
                policy='Known hosts: 503 on HTTP and configured HTTPS; unknown HTTP: 404; no default TLS certificate; unmatched HTTPS requests: 404')


PAGE = '''(maintenance) {
    header Content-Type "text/html; charset=utf-8"
    header Cache-Control "no-store"
    header Retry-After "600"
    respond "<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Temporarily Offline</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f8f9fa;color:#252525;text-align:center;padding:24px;box-sizing:border-box}main{max-width:540px}p{color:#666;line-height:1.7}.status{background:#fff3cd;color:#856404;border-radius:6px;padding:8px 16px}</style></head><body><main><span class='status'>Temporary Maintenance</span><h1>We'll Be Right Back</h1><p>This website is temporarily offline while we perform important security maintenance.</p><p>Thank you for your patience.</p></main></body></html>" 503
}
'''


def summary(plan):
    print('Found the following available sites:')
    for site in plan['sites']:
        for host in site['hosts']:
            status = ('has certificate' if site['certificate'] else
                      'HTTP only - HTTPS unavailable' if site.get('https_error') else 'HTTP only (no certificate)')
            print(f'  {host} - {status}')
    for note in plan['notes']:
        if not note.startswith('Ignored unnamed/default'):
            print(f'  Note: {note}')


def build(plan, target):
    root = Path(target)
    # Caller must supply an empty private release directory; never overwrite files.
    if any(root.iterdir()):
        raise Invalid(f'Release directory is not empty: {root}')
    (root / 'sites').mkdir()
    (root / 'certs').mkdir()
    (root / 'maintenance.caddy').write_text(PAGE)
    (root / 'Caddyfile').write_text('''{
    admin off
    auto_https off
}
''' + f'import {root}/maintenance.caddy\nimport {root}/sites/*.caddy\n' + '''http:// {
    respond "Unknown host" 404
}
https:// {
    respond "Unknown host" 404
}
''')
    for i, site in enumerate(plan['sites'], 1):
        names = site['hosts']
        text = ', '.join('http://' + h for h in names) + ' {\n    import maintenance\n}\n'
        if site['certificate']:
            cert, key = root / 'certs' / f'{i}.crt', root / 'certs' / f'{i}.key'
            shutil.copyfile(site['certificate'], cert)
            shutil.copyfile(site['key'], key)
            os.chmod(key, 0o640)
            # Validate the copied bytes too, not just the original paths.
            certificate(str(cert), str(key), names, plan['minimum_valid_seconds'])
            text += ', '.join('https://' + h for h in names) + f' {{\n    tls {cert} {key}\n    import maintenance\n}}\n'
        (root / 'sites' / f'{i:03d}-{names[0]}.caddy').write_text(text)
    (root / 'inventory.json').write_text(json.dumps(plan, indent=2) + '\n')


def probe(plan, ip):
    for site in plan['sites']:
        for host in site['hosts']:
            for scheme, port in [('http', 80)] + ([('https', 443)] if site['certificate'] else []):
                p = subprocess.run(['curl', '--noproxy', '*', '--silent', '--show-error',
                                    '--connect-timeout', '3', '--max-time', '10', '--resolve',
                                    f'{host}:{port}:{ip}', '-D', '-', '-o', '/dev/null', f'{scheme}://{host}/'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                headers = p.stdout.decode().lower()
                if p.returncode or not re.search(r'^http/\S+ 503\b', headers, re.M) or 'retry-after: 600' not in headers or 'cache-control: no-store' not in headers:
                    raise Invalid(f'Probe failed: {scheme}://{host}/ via {ip}; check journal and certificate chain/trust')
            protocol = 'HTTP/HTTPS' if site['certificate'] else 'HTTP'
            print(f'  {host} - {protocol} OK')
    p = subprocess.run(['curl', '--noproxy', '*', '-sS', '--max-time', '5', '-o', '/dev/null',
                        '-w', '%{http_code}', '-H', 'Host: unknown.invalid', f'http://{ip}/'], stdout=subprocess.PIPE)
    if p.returncode or p.stdout != b'404':
        raise Invalid('Unknown HTTP Host did not return 404')


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('discover')
    d.add_argument('--enabled', default='/etc/nginx/sites-enabled')
    d.add_argument('--prefix', default='/etc/nginx')
    d.add_argument('--minimum-valid-seconds', type=int, default=86400)
    d.add_argument('--expand-name', action='append', default=[], metavar='.DOMAIN=HOST1,HOST2')
    limited = sub.add_parser('limitations')
    limited.add_argument('plan')
    h = sub.add_parser('summary')
    h.add_argument('plan')
    b = sub.add_parser('build')
    b.add_argument('plan')
    b.add_argument('target')
    v = sub.add_parser('probe')
    v.add_argument('plan')
    v.add_argument('--ip', default='127.0.0.1')
    c = sub.add_parser('check')
    c.add_argument('plan')
    a = p.parse_args()
    if a.cmd == 'discover':
        if a.minimum_valid_seconds < 0:
            raise Invalid('minimum-valid-seconds must be nonnegative')
        plan = inventory(a.enabled, a.prefix, a.minimum_valid_seconds, expansions(a.expand_name))
        plan['minimum_valid_seconds'] = a.minimum_valid_seconds
        print(json.dumps(plan, indent=2))
    else:
        plan = json.loads(Path(a.plan).read_text())
        if a.cmd == 'limitations':
            for site in plan['sites']:
                if site.get('https_error'):
                    print(f"HTTPS unavailable: {', '.join(site['hosts'])}. HTTP only until the certificate/key is repaired and Popcorn redeployed.")
        elif a.cmd == 'summary':
            summary(plan)
        elif a.cmd == 'build':
            build(plan, a.target)
        elif a.cmd == 'probe':
            probe(plan, a.ip)
        else:
            # Rollback must check the release copies, not the current Forge source paths.
            root = Path(a.plan).parent
            for i, site in enumerate(plan['sites'], 1):
                if site['certificate']:
                    warning = certificate(str(root / 'certs' / f'{i}.crt'), str(root / 'certs' / f'{i}.key'),
                                          site['hosts'], plan['minimum_valid_seconds'])
                    if warning:
                        print(f'Warning: {warning}', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except (Invalid, OSError, ValueError) as exc:
        sys.exit(f'ERROR: {exc}')
POPCORN_EMBEDDED_PYTHON
}

command=${1:-help}
[[ $# == 0 ]] || shift
case "$command" in help|-h|--help) usage; exit 0;; esac
root
check_platform
# Lock is outside the managed tree, so dry-run does not create permanent config.
[[ ! -L /run/lock/popcorn.lock ]] || die 'Lock is a symlink.'
exec 9>/run/lock/popcorn.lock
flock -n 9 || die 'Another popcorn command is running.'
TMP=$(mktemp -d)
case "$command" in
    dry-run)
        discovered=0
        if discovery discover "$@" > "$TMP/inventory.json"; then
            discovered=1
        fi
        readiness_report "$discovered" "$@"
        # Running Nginx or missing Caddy are expected findings, not dry-run failures.
        [[ $discovered == 1 ]] || exit 1
        ;;
    deploy)
        discovery discover "$@" > "$TMP/inventory.json"
        discovery summary "$TMP/inventory.json"
        [[ -x /usr/bin/caddy ]] || die 'Caddy is missing: run the install command first.'
        if ! getent passwd caddy >/dev/null || ! getent group caddy >/dev/null; then
            die 'Package caddy user/group missing.'
        fi
        check_layout
        ports_available
        init_layout
        release_id="$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
        backup "$release_id"
        python3 - "$TMP/inventory.json" "$ROOT/backups/$release_id/included-sources.tar" <<'PY'
import json, sys, tarfile
with tarfile.open(sys.argv[2], 'x') as archive:
    for source in json.load(open(sys.argv[1]))['sources']:
        archive.add(source, arcname=source.lstrip('/'), recursive=False)
PY
        release="$ROOT/releases/$release_id"
        mkdir -m 0750 "$release"
        discovery build "$TMP/inventory.json" "$release"
        chown -R root:caddy "$release"
        find "$release" -type d -exec chmod 0750 {} +
        find "$release" -type f -exec chmod 0640 {} +
        validate "$release"
        touch "$release/complete"
        activate "$release"
        ;;
    install)
        [[ $# == 0 ]] || die 'install takes no options.'
        if [[ -x /usr/bin/caddy ]]; then /usr/bin/caddy version; exit 0; fi
        need apt-get
        if systemctl cat caddy.service >/dev/null 2>&1 || [[ -e /etc/caddy/Caddyfile ]]; then
            die 'Existing stock Caddy installation/config without its binary; restore it explicitly before using install.'
        fi
        [[ ! -e /run/systemd/system/caddy.service && ! -L /run/systemd/system/caddy.service ]] || die 'Existing runtime Caddy mask/override; inspect before installing.'
        systemctl is-active --quiet caddy.service && die 'Stock Caddy is active.'
        # Mask before APT so package scripts cannot claim ports 80/443.
        ln -s /dev/null /run/systemd/system/caddy.service
        MASKED=1
        systemctl daemon-reload
        # No repository changes, upgrade, or apt update: use the administrator's configured candidate.
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o Dpkg::Options::=--force-confold install -y --no-upgrade --no-install-recommends caddy
        # A newly installed package can enable its default service. Prevent a boot-time port conflict.
        systemctl disable caddy.service
        [[ -x /usr/bin/caddy ]] || die 'Package did not provide /usr/bin/caddy.'
        /usr/bin/caddy version
        log 'Caddy installed. Its new stock service is disabled at boot and was not started.'
        log 'Next, check the sites and remaining deployment steps:'
        next_command dry-run
        ;;
    status)
        [[ $# == 0 ]] || die 'status takes no options.'
        systemctl --no-pager status "$SERVICE" || true
        [[ ! -L $ROOT/current ]] || readlink "$ROOT/current"
        [[ ! -d $ROOT/releases ]] || find "$ROOT/releases" -mindepth 2 -maxdepth 2 -name complete -printf '%h\n'
        ;;
    verify)
        check_layout
        [[ -n $OLD ]] || die 'No current release.'
        active || die 'Maintenance is not active.'
        discovery probe "$OLD/inventory.json" "$@"
        ;;
    stop)
        [[ $# == 0 ]] || die 'stop takes no options.'
        stop_popcorn
        ;;
    teardown)
        teardown "$@"
        ;;
    rollback)
        [[ $# == 1 ]] || die 'rollback requires a release ID. Use stop to end maintenance.'
        if [[ $1 == off ]]; then
            stop_popcorn
            exit 0
        fi
        check_layout
        [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$ ]] || die 'Invalid release ID.'
        release="$ROOT/releases/$1"
        [[ -d $release && ! -L $release && -f $release/complete ]] || die 'No complete release with that ID.'
        ports_available
        discovery check "$release/inventory.json"
        validate "$release"
        backup "rollback-$(date -u +%Y%m%dT%H%M%SZ)-$1"
        activate "$release"
        ;;
    *) usage >&2; die "Unknown command: $command";;
esac