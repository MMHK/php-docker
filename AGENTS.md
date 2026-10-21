# AGENTS.md

## What this is

Single Docker image: PHP 8.0 FPM published as `mmhk/php-docker:8.0-fpm`. PHP is
compiled from the official **8.0.30** source in `debian:bullseye-slim` (mirroring
docker-library/php 8.0/bullseye/fpm) with the backport patch for
**CVE-2026-109618 / CVE-2026-109619** applied
(`patches/php-8.0-CVE-2026-109618-109619.patch`). No application code, no tests,
no lint.

## Commands

```bash
docker compose build          # build locally (compiles PHP + ~20 extensions; slow cold)
docker compose up             # run
```

Release: push a `v*` tag → GitHub Actions builds multi-arch (amd64/arm64) and
pushes to Docker Hub. The image tag is always `8.0-fpm` regardless of git tag. A
`security-gate` job runs `scripts/cve-gate.php` (L0/L1) and
`scripts/oom-semantics.php` (L2) before publishing.

## Gotchas

- **Debian bullseye is EOL**: the Dockerfile repoints apt to `archive.debian.org`
  and disables `Acquire::Check-Valid-Until`; otherwise bullseye-security 404s and
  every `apt-get install` fails.
- **PHP is built from source** (not `FROM php:8.0-fpm-bullseye`): official 8.0.30
  tarball pinned by `PHP_SHA256`, then `docker-php-source extract` +
  `patch -p1 --fuzz=0`. The vendored `docker-php-scripts/` (from
  docker-library/php@41c9ad0) are required by `docker-php-source` and
  `install-php-extensions`.
- **CVE marker is mandatory for release**: the image must carry
  `/usr/local/etc/php/cve-2026-109618-109619.patched` with both CVE IDs, the
  40-hex commit and the branch declaration; the L0 gate fails closed without it.
- **redis is not installed from the PECL channel**: pecl.php.net answers PEAR's
  REST metadata request with gzip, which PEAR cannot parse. The Dockerfile
  downloads the pinned tarball (`REDIS_VERSION` / `REDIS_SHA256`), extracts it to
  `/usr/src/redis` with `package.xml` alongside the sources, and passes that
  directory to `install-php-extensions`.
- The patch is verified to apply to 8.0.30 with zero fuzz and to reproduce the
  upstream branch byte-for-byte; do not hand-edit it.
- Timezone is hardcoded to `Asia/Hong_Kong` in the Dockerfile.
- `pm.max_requests = 5` in FPM config (intentionally low — forces frequent worker
  recycling).
- Entrypoint sets `umask 0000` (world-writable files).
- Extensions installed via
  [mlocati/install-php-extensions](https://github.com/mlocati/docker-php-extension-installer),
  wrapped in a 5-attempt retry loop. `docker-php-ext-configure` is not needed —
  the script handles configure/install/enable internally.
- Opcache is installed by `install-php-extensions` (compiled from the patched
  source). JIT config lives in `opcache.ini` (COPY to
  `/usr/local/etc/php/conf.d/`), **not** via `php_admin_value` in FPM pool config
  (JIT directives like `opcache.jit_buffer_size` are `INI_SYSTEM` and don't work
  reliably through `php_admin_value`).
- PHP 8.0 JIT defaults: `opcache.jit=tracing` and `opcache.jit_buffer_size=0`
  (disabled). Must set buffer size to enable JIT.
