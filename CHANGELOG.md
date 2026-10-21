# Changelog

## 2.0.1 — 2026-10-21

- MIT licensed. The script carries an SPDX license header, so the license travels with the downloaded file.
- README: where Popcorn works beyond Forge (tested on Ubuntu 24.04 and Debian 12 with Certbot), and a demo GIF.

## 2.0.0 — 2026-10-21

Rewritten from scratch: ~300 lines of bash instead of ~1,100 lines of bash and embedded Python.

- Reads certificates from `nginx -T` and serves the hostnames each certificate covers. Port 80 answers every hostname.
- Caddy runs as a transient `popcorn.service`; generated files live in `/run/popcorn`. Nothing persists across a reboot.
- Installs as `/usr/local/bin/popcorn`; commands are `check`, `install`, `start`, `status`, `stop` and `version`. Re-running the install command updates it.
- README quick start: one line (over SSH, or as a root Forge Recipe) that installs Popcorn, stops Nginx and starts Popcorn, and starts Nginx again if Popcorn can't start.
- `start` and `stop` migrate a v1 deployment automatically.
- Releases are published from tags, with `popcorn.sh` attached.

## 1.0.0

Original script, shared as a gist.
