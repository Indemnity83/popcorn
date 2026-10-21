# Popcorn 🍿

Take your Laravel Forge sites offline and wait for the dust to settle.

Popcorn serves static HTTP/HTTPS **503 maintenance pages** through Caddy while Nginx is stopped. The server stays running and accessible over SSH. It discovers enabled sites and reuses their existing certificates—no PHP required to serve the page.

## Start here

Save `popcorn.sh` on an Ubuntu Forge server and run:

```bash
sudo bash popcorn.sh dry-run
```

It lists sites, checks certificates, and reports the next steps: missing Caddy, running Nginx, occupied ports, or configuration problems. **Dry-run changes no services or persistent configuration.** No companion files or installation directory are needed; Python 3 must be installed.

## Go offline

Follow the dry-run's guidance. If Caddy is missing:

```bash
sudo bash popcorn.sh install
```

When ready, stop Nginx and deploy the maintenance pages:

```bash
sudo systemctl stop nginx.service
sudo bash popcorn.sh deploy
sudo bash popcorn.sh verify
```

Popcorn never stops Nginx, PHP-FPM, or workers itself. Manage PHP and application workers separately if the incident requires it. If ports are occupied, deployment stops without stopping the existing service. Successful deployment checks the configuration and each HTTP/HTTPS endpoint.

Check a normal public site URL from another machine too. Expect **503**, `Retry-After: 600`, and `Cache-Control: no-store`. For troubleshooting:

```bash
sudo journalctl -u popcorn.service -n 50 --no-pager
```

Routine validation output is saved under `/etc/popcorn/logs/`. Deployment waits for validation to finish; failures show their error details.

## Bring sites back

Finish and verify the updates, restore any PHP-FPM services that were stopped, and check Nginx configuration while Popcorn is still running:

```bash
sudo nginx -t
```

Once ready, `stop` ends the holding pages and keeps Popcorn's files and backups for reuse:

```bash
sudo bash popcorn.sh stop
```

`teardown` stops Popcorn and removes its generated files and backups. It can run directly or after `stop`:

```bash
sudo bash popcorn.sh teardown --dry-run
sudo bash popcorn.sh teardown
```

**Teardown deletes all Popcorn releases, copied keys, and backups.** It leaves Caddy installed and original Forge/Nginx files untouched.

Neither option starts Nginx. After maintenance stops and the web ports are free:

```bash
sudo nginx -t && sudo systemctl start nginx.service
```

Check the public sites again. `popcorn.service` and stock `caddy.service` are separate; if stock Caddy was also used for maintenance, stop/disable it before starting Nginx.

## Worth knowing

- Intended for standard Ubuntu Forge configurations using `/etc/nginx/sites-enabled` and ports 80/443. Review the discovered sites; unsupported or ambiguous configurations are refused.
- Leading-dot Forge names such as `.example.com` are handled automatically using the base domain and matching concrete names in the configured certificate. Certificate wildcards are not enumerated into arbitrary subdomains.
- Certificates must cover configured HTTPS names, match their keys, and have at least 24 hours remaining. HTTP-only sites stay HTTP-only. Certificates are copied, not renewed.
- A certificate issue affects only its site: expired or unusable certificates mean HTTP only, clearly listed in dry-run. Valid certificates with less than 24 hours remaining warn without blocking deployment. HTTPS requires a matching, valid certificate; repair it and redeploy to restore HTTPS. Certificates are copied, not renewed.
- Known hosts get 503; unknown HTTP hosts get 404. Unknown HTTPS requests get 404 if TLS completes, or fail the handshake without a matching certificate.
- Popcorn is **not enabled at boot**. Existing Nginx/Caddy boot settings still apply after a reboot.
- Caddy installation uses configured APT repositories and leaves its newly installed stock service disabled. Original Nginx/Caddy configurations and certificates are not edited.
- Releases and key-bearing backups live under `/etc/popcorn/`. To restore a previous maintenance release, run `status`, then `rollback RELEASE_ID`.
- Discovery, deployment, stop, and teardown have been exercised on an Ubuntu Forge server with Caddy already installed. Run dry-run and verification on each server.

Run `sudo bash popcorn.sh --help` for commands, discovery options, and recovery details.