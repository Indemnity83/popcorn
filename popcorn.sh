#!/usr/bin/env bash
# SPDX-License-Identifier: MIT · Copyright (c) 2026 Kyle Klaus · https://github.com/Indemnity83/popcorn
# Popcorn 🍿 — put a 503 maintenance page in front of every site on a Laravel
# Forge server while Nginx is stopped, using Caddy and the certificates Nginx
# is already configured with. Then wait for the dust to settle.
#
#   sudo popcorn check      # show what would be served; changes nothing
#   sudo popcorn install    # install Caddy with apt, if it's missing
#   sudo systemctl stop nginx
#   sudo popcorn start      # serve the maintenance page
#   sudo popcorn status     # confirm every hostname answers 503
#   ...patch PHP...
#   sudo popcorn stop       # stop serving and delete generated files
#   sudo nginx -t && sudo systemctl start nginx
#
#   popcorn version         # show this script's version
#
# Install or update: download the latest release to /usr/local/bin/popcorn
# (see the README at https://github.com/Indemnity83/popcorn).
#
# Footprint: generated files live only in /run/popcorn (tmpfs, gone on reboot)
# and Caddy runs as a transient systemd unit, popcorn.service, that is never
# enabled at boot. Popcorn never edits Nginx config, and never starts or stops
# Nginx, PHP-FPM or queue workers.

set -euo pipefail
set -f # no globbing: certificate names like *.example.com must stay literal
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077

VERSION=2.0.1 # must match the release tag; v1 was the original ~1,100-line script
DIR=/run/popcorn
UNIT=popcorn.service
SITES=() # one entry per usable certificate: "cert key host1 host2 ..."

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
running() { systemctl is-active --quiet "$UNIT"; }
ports_in_use() { # "tcp 0.0.0.0:80 nginx" per listener on 80/443
    ss -Hlntup '( sport = :80 or sport = :443 )' | awk '{ split($NF, p, "\""); print "  " $1, $5, p[2] }'
}
require_free_ports() {
    local busy
    busy=$(ports_in_use)
    [[ -z $busy ]] || die $'Ports 80/443 are in use (is Nginx still running?)\n'"$busy"
}

# Popcorn v1 installed a permanent popcorn.service and kept releases,
# certificate copies and backups in /etc/popcorn. start and stop remove it
# (as its teardown did), freeing the unit name for this version.
LEGACY_UNIT=/etc/systemd/system/popcorn.service
legacy() { [[ -e /etc/popcorn || -e $LEGACY_UNIT ]]; }
remove_legacy() {
    legacy || return 0
    # Only delete what that version's own ownership markers vouch for.
    [[ ! -e /etc/popcorn ]] || grep -qx 'popcorn v1' /etc/popcorn/managed-v1 2>/dev/null ||
        die '/etc/popcorn was not created by Popcorn; refusing to remove it.'
    [[ ! -e $LEGACY_UNIT ]] || grep -qx '# Managed by popcorn v1.*' "$LEGACY_UNIT" ||
        die "$LEGACY_UNIT was not created by Popcorn; refusing to remove it."
    log 'Removing Popcorn v1, including its certificate copies and backups...'
    systemctl stop "$UNIT" 2>/dev/null || true
    rm -rf --one-file-system /etc/popcorn /var/lib/popcorn
    rm -f "$LEGACY_UNIT"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" 2>/dev/null || true
}

# Print "cert key" for each TLS pair in the Nginx config. `nginx -T` resolves
# every include and only parses; it doesn't need or touch a running Nginx.
# Server blocks without a real server_name are skipped: Forge's catch-all
# uses a self-signed placeholder certificate (for www.example.com).
nginx_tls_pairs() {
    # Drop comments and put each statement on its own line before reading.
    nginx -T 2>/dev/null | sed 's/#.*//' | tr '{};' '\n' | awk '
        function flush() { if (cert && key && named) print cert, key; cert = key = named = "" }
        { gsub(/["\047]/, "") }
        $1 == "server" && NF == 1   { flush() }
        $1 == "server_name"         { for (i = 2; i <= NF; i++) if ($i != "_") named = 1 }
        $1 == "ssl_certificate"     { cert = $2 }
        $1 == "ssl_certificate_key" { key = $2 }
        END                         { flush() }
    ' | sort -u
}

# DNS names from a certificate's subjectAltName, lowercased, one per line.
cert_names() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null |
        grep -o 'DNS:[^,]*' | cut -c5- | tr '[:upper:]' '[:lower:]' || true
}

# Fill SITES from Nginx's certificates, skipping any that can't be served.
# HTTPS hostnames come from each certificate, so they are covered by
# construction. Plain HTTP needs no list: Caddy answers every host on :80.
plan() {
    local pairs cert key name names kept
    local -A owner=()
    pairs=$(nginx_tls_pairs) || { nginx -t || true; die 'Nginx config does not parse; fix it first.'; }
    while read -r cert key; do
        [[ -n $cert ]] || continue
        if [[ ! -r $cert || ! -r $key ]]; then
            log "  Skipping $cert: certificate or key file is missing."; continue
        elif ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
            log "  Skipping $cert: expired or unreadable (those sites get HTTP only)."; continue
        elif [[ $(openssl x509 -in "$cert" -noout -pubkey) != "$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null)" ]]; then
            log "  Skipping $cert: it does not match $key."; continue
        fi
        if ! openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null; then
            log "  Warning: $cert expires within 24 hours."
        fi
        kept=()
        mapfile -t names < <(cert_names "$cert")
        for name in "${names[@]}"; do
            if [[ -n ${owner[$name]:-} ]]; then
                log "  Note: $name is already served with ${owner[$name]}."; continue
            fi
            owner[$name]=$cert
            kept+=("$name")
        done
        if (( ${#kept[@]} )); then SITES+=("$cert $key ${kept[*]}"); fi
    done <<< "$pairs"
}

# Write the Caddyfile and a hostname list into $DIR, along with root:caddy
# copies of the certificates (Caddy runs as the caddy user; Forge keys are
# readable by root only).
write_config() {
    local i=0 site f addrs
    {
        cat <<'EOF'
{
	admin off
	auto_https off
	servers {
		protocols h1 h2
	}
}

(maintenance) {
	header Content-Type "text/html; charset=utf-8"
	header Cache-Control "no-store"
	header Retry-After "600"
	respond "<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Temporarily Offline</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f8f9fa;color:#252525;text-align:center;padding:24px;box-sizing:border-box}
main{max-width:540px}
p{color:#666;line-height:1.7}
.status{background:#fff3cd;color:#856404;border-radius:6px;padding:8px 16px}
</style>
</head>
<body>
<main>
<span class='status'>Temporary Maintenance</span>
<h1>We'll Be Right Back</h1>
<p>This website is temporarily offline while we perform important security maintenance.</p>
<p>Thank you for your patience.</p>
</main>
</body>
</html>" 503
}

http:// {
	import maintenance
}
EOF
        for site in "${SITES[@]}"; do
            read -ra f <<< "$site"
            (( ++i ))
            install -m 0640 -g caddy "${f[0]}" "$DIR/$i.crt"
            install -m 0640 -g caddy "${f[1]}" "$DIR/$i.key"
            addrs=$(printf 'https://%s, ' "${f[@]:2}")
            printf '\n%s {\n\ttls %s %s\n\timport maintenance\n}\n' "${addrs%, }" "$DIR/$i.crt" "$DIR/$i.key"
            printf '%s\n' "${f[@]:2}" >> "$DIR/hosts" # for probe
        done
    } > "$DIR/Caddyfile"
    chgrp caddy "$DIR/Caddyfile"
    chmod 0640 "$DIR/Caddyfile"
}

check_url() { # scheme host port
    local code note=''
    local curl=(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' --resolve "$2:$3:127.0.0.1")
    code=$("${curl[@]}" "$1://$2/") || true
    # Cloudflare Origin and self-signed certificates work but aren't publicly trusted.
    if [[ $code == 000 && $1 == https ]] && code=$("${curl[@]}" --insecure "$1://$2/"); then
        note='  (certificate not publicly trusted; fine behind Cloudflare)'
    fi
    log "  $code  $1://$2/$note"
    [[ $code == 503 ]]
}

# Request each hostname from this server.
probe() {
    local host failed=0
    check_url http any-hostname.invalid 80 || failed=1
    [[ -e $DIR/hosts ]] || return "$failed" # no HTTPS sites
    while read -r host; do
        [[ $host == \** ]] || check_url https "$host" 443 || failed=1
    done < "$DIR/hosts"
    return "$failed"
}

check() {
    log 'Reading certificates from the Nginx config...'
    plan
    log ''
    log 'HTTP (port 80): every hostname gets the maintenance page.'
    log 'HTTPS (port 443):'
    if (( ! ${#SITES[@]} )); then log '  none'; fi
    local site f busy ready=1
    for site in "${SITES[@]}"; do
        read -ra f <<< "$site"
        log "  ${f[*]:2}  (${f[0]})"
    done
    log ''
    if [[ ! -x /usr/bin/caddy ]]; then
        ready=0; log 'Caddy is not installed: sudo popcorn install'
    fi
    legacy && log 'Popcorn v1 is installed; start will replace it (removing /etc/popcorn).'
    if running; then
        legacy || { ready=0; log 'Popcorn is already running.'; } # start replaces a running v1
    elif busy=$(ports_in_use) && [[ -n $busy ]]; then
        ready=0; log "Ports 80/443 are in use. Stop Nginx when you're ready: sudo systemctl stop nginx"
        log "$busy"
    fi
    if (( ready )); then log 'Ready: sudo popcorn start'; fi
    log 'Nothing was changed.'
}

start() {
    [[ -x /usr/bin/caddy ]] || die 'Caddy is not installed. Run: sudo popcorn install'
    if ! legacy; then # a running v1 holds the ports until it is replaced below
        running && die 'Popcorn is already running. Run stop, then start, to regenerate it.'
        require_free_ports
    fi
    log 'Reading certificates from the Nginx config...'
    plan
    rm -rf "$DIR"
    install -d -m 0750 -g caddy "$DIR"
    write_config
    if ! runuser -u caddy -- caddy validate --config "$DIR/Caddyfile" --adapter caddyfile > "$DIR/validate.log" 2>&1; then
        tail -n 20 "$DIR/validate.log" >&2
        die "Caddy rejected the generated config: $DIR/Caddyfile"
    fi
    remove_legacy # only after the new config validates, to keep v1's downtime short
    require_free_ports
    systemd-run --quiet --unit="$UNIT" --description="Popcorn $VERSION maintenance page" \
        -p CollectMode=inactive-or-failed -p Restart=on-failure \
        -p User=caddy -p Group=caddy \
        -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p CapabilityBoundingSet=CAP_NET_BIND_SERVICE \
        -p NoNewPrivileges=yes -p ProtectSystem=full -p ProtectHome=yes -p PrivateTmp=yes \
        /usr/bin/caddy run --config "$DIR/Caddyfile" --adapter caddyfile
    for _ in 1 2 3 4 5; do # give Caddy up to 5s to bind its ports
        [[ -z $(ports_in_use) ]] || break
        sleep 1
    done
    running || die 'Caddy did not start. See: sudo journalctl -u popcorn -n 50 --no-pager'
    log 'Checking each hostname from this server:'
    probe || die 'Popcorn is running, but some checks failed (see above).'
    log ''
    log '🍿 Maintenance page is up. Go get your popcorn!'
    log 'Check a public URL from another machine too: expect 503 and Retry-After: 600.'
}

status() {
    legacy && die 'Popcorn v1 is installed. Run start to switch to this version.'
    running || die 'Popcorn is not running.'
    log "$(systemctl show "$UNIT" -p Description --value) is running (this script is $VERSION)."
    log 'Checking each hostname from this server:'
    probe || die 'Some checks failed. See: sudo journalctl -u popcorn -n 50 --no-pager'
}

stop() {
    remove_legacy
    systemctl stop "$UNIT" 2>/dev/null || true
    rm -rf "$DIR"
    log 'Popcorn stopped and its generated files removed.'
    log 'Once PHP is patched: sudo nginx -t && sudo systemctl start nginx'
}

install_caddy() {
    if [[ -x /usr/bin/caddy ]]; then /usr/bin/caddy version; return; fi
    local mask=/run/systemd/system/caddy.service
    [[ ! -e $mask && ! -L $mask ]] || die "$mask already exists; inspect it first."
    # Mask the package's own caddy.service while installing, so the package
    # can't start a second web server on ports 80/443. The mask is runtime-only.
    ln -s /dev/null "$mask"
    # shellcheck disable=SC2064 # expand $mask now; it is local
    trap "rm -f $mask; systemctl daemon-reload" EXIT
    systemctl daemon-reload
    # NEEDRESTART_MODE=l lists services needing a restart instead of restarting
    # them, so installing Caddy can't bounce PHP-FPM.
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        apt-get install -y --no-install-recommends caddy ||
        die "apt could not install caddy. If your Ubuntu release doesn't package it, add Caddy's repo: https://caddyserver.com/docs/install#debian-ubuntu-raspbian"
    rm -f "$mask"
    systemctl daemon-reload
    trap - EXIT
    systemctl disable --quiet caddy.service || true # Popcorn runs its own unit
    /usr/bin/caddy version
    log 'Caddy installed; its stock service is disabled and was not started.'
    log 'Next: sudo popcorn check'
}

case ${1:-} in
    check | install | start | status | stop) ;;
    version | --version) echo "popcorn $VERSION"; exit 0 ;;
    *) echo "popcorn $VERSION"; sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac
[[ $EUID == 0 ]] || die 'Run with sudo.'
for cmd in nginx openssl curl ss systemctl systemd-run runuser; do
    command -v "$cmd" >/dev/null || die "Missing required command: $cmd"
done
case $1 in
    check) check ;;
    install) install_caddy ;;
    start) start ;;
    status) status ;;
    stop) stop ;;
esac
