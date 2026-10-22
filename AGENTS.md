# AGENTS.md

## What this is

Single Docker image: PHP 8.4 FPM on `php:8.4.27-fpm-bookworm`, published as `mmhk/php-docker:8.4-fpm`. No application code, no tests, no lint.

The base tag is pinned to an exact patch version on purpose (CVE-2026-109618/109619 fix landed in 8.4.27). Bump it manually on each PHP security release — see `docs/plans/php-8.4-cve-2026-109618-109619-patch.md`.

## Commands

```bash
docker compose build          # build locally
docker compose up             # run
```

Release: push a `v*` tag → GitHub Actions builds multi-arch (amd64/arm64) and pushes to Docker Hub. The image tag is always `8.4-fpm` regardless of git tag.

## Gotchas

- Timezone is hardcoded to `Asia/Hong_Kong` in the Dockerfile.
- `pm.max_requests = 5` in FPM config (intentionally low — forces frequent worker recycling).
- Entrypoint sets `umask 0000` (world-writable files).
- Extensions installed via [mlocati/install-php-extensions](https://github.com/mlocati/docker-php-extension-installer). `docker-php-ext-configure` is not needed — the script handles configure/install/enable internally.
- Opcache is pre-installed in the base image. JIT config lives in `opcache.ini` (COPY to `/usr/local/etc/php/conf.d/`), **not** via `php_admin_value` in FPM pool config (JIT directives like `opcache.jit_buffer_size` are `INI_SYSTEM` and don't work reliably through `php_admin_value`).
