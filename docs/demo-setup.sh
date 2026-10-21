#!/usr/bin/env bash
# Start a disposable, Forge-like Ubuntu server in Docker for recording the
# demo GIF. Then, from the repo root: vhs docs/demo.tape
# Remove it afterwards with: docker rm -f demo
#
# The container runs systemd, so it needs --privileged. It has two HTTPS
# sites with certificates from a throwaway CA that only the container trusts.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -q -t popcorn-demo - <<'EOF' >/dev/null
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    systemd systemd-sysv nginx caddy openssl curl iproute2 ca-certificates sudo \
    && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

docker rm -f demo >/dev/null 2>&1 || true
docker run -d --name demo --hostname brave-meadow --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw popcorn-demo >/dev/null
# "degraded" is normal in a container; is-system-running exits non-zero for it.
until [[ $(docker exec demo systemctl is-system-running --wait 2>/dev/null) =~ running|degraded ]]; do sleep 1; done
docker cp popcorn.sh demo:/usr/local/bin/popcorn

docker exec -i demo bash -s <<'EOF'
set -euo pipefail
chmod 0755 /usr/local/bin/popcorn
systemctl disable --now caddy -q # Popcorn runs its own unit

cd /root
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 30 -subj /CN=DemoCA 2>/dev/null
cp ca.crt /usr/local/share/ca-certificates/demo.crt
update-ca-certificates >/dev/null 2>&1

# A Forge-style site: TLS server block, plus an HTTP redirect in forge-conf.
n=100
site() { # domain [more names...]
    local d=$1 dir; n=$((n + 1)); dir=/etc/nginx/ssl/$d/$n
    mkdir -p "$dir" "/etc/nginx/forge-conf/$d/before"
    printf 'subjectAltName=%s\n' "$(printf 'DNS:%s,' "$@" | sed 's/,$//')" > "$dir/ext"
    openssl req -newkey rsa:2048 -nodes -keyout "$dir/server.key" -out "$dir/req.csr" -subj "/CN=$d" 2>/dev/null
    openssl x509 -req -in "$dir/req.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 60 \
        -extfile "$dir/ext" -out "$dir/server.crt" 2>/dev/null
    cat > "/etc/nginx/sites-available/$d" <<CONF
include forge-conf/$d/before/*;
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $*;
    root /home/forge/$d/public;
    ssl_certificate $dir/server.crt;
    ssl_certificate_key $dir/server.key;
}
CONF
    printf 'server {\n    listen 80;\n    server_name %s;\n    return 301 https://$host$request_uri;\n}\n' "$*" \
        > "/etc/nginx/forge-conf/$d/before/redirect.conf"
    ln -sf "/etc/nginx/sites-available/$d" "/etc/nginx/sites-enabled/$d"
}
rm -f /etc/nginx/sites-enabled/default
site example.com www.example.com
site shop.example.org
printf 'server {\n    listen 80 default_server;\n    listen 443 ssl default_server;\n    server_name _;\n    ssl_reject_handshake on;\n    return 444;\n}\n' \
    > /etc/nginx/sites-enabled/000-catch-all
systemctl restart nginx

# Make the demo domains resolve to this container, not the real internet.
echo '127.0.0.1 example.com www.example.com shop.example.org' >> /etc/hosts

useradd -m -s /bin/bash forge
echo 'forge ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/forge
echo "PS1='\[\e[1;32m\]forge@brave-meadow\[\e[0m\]:\[\e[1;34m\]~\[\e[0m\]\\$ '" >> /home/forge/.bashrc
EOF
echo 'Demo server is running. Record with: vhs docs/demo.tape'
