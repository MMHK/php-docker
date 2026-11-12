# AGENTS.md

## What this is

Single Docker image: PHP 8.0 FPM published as `mmhk/php-docker:8.0-fpm`. PHP is
compiled from the official **8.0.30** source in `debian:bullseye-slim` (mirroring
docker-library/php 8.0/bullseye/fpm) with the backport patch for
**CVE-2026-109618 / CVE-2026-109619** applied
(`patches/php-8.0-CVE-2026-109618-109619.patch`). Extensions are linked
**statically** into `php` / `php-fpm`; only OPcache and sodium are `.so`.
No application code, no test suite, no lint.

## Layout

```
Dockerfile                  base / builder / runtime (three stages)
scripts/
  build-php-static.sh       builder entrypoint: PHP + static extensions
  static-extensions.conf    extension -> configure flags (TAB-separated)
  README.md                 build flow, add/bump extension, debugging
docker-php-scripts/         builder helpers (source, ext-enable, clean,
                            static-install, static-remove)
patches/                    CVE backport patch
docs/
  README.md                 documentation index (current vs archived)
  plans/                    current design/verification documents
  archive/                  superseded documents (keep history, add notice)
tests/                      verify-ca-bundle.php (not copied into the image)
.github/workflows/          native multi-arch release
```

Where to read first: `README.md` for usage, `docs/README.md` for the document
index, `docs/plans/php-8.0-static-extensions.md` for how PHP/extensions are
built, `scripts/README.md` for adding or bumping an extension.

## Commands

```bash
docker compose build          # build locally (compiles PHP + 22 extensions; slow cold)
docker compose up             # run
docker build --target builder -t mmhk/php-docker:8.0-fpm-builder .
                              # builder stage: PHP source + toolchain + static helpers
```

Release: push a `v*` tag → GitHub Actions builds multi-arch (amd64/arm64) and
pushes to Docker Hub. The image tag is always `8.0-fpm` regardless of git tag.
Each architecture is built **natively** (amd64 on `ubuntu-latest`, arm64 on
`ubuntu-24.04-arm`) — no QEMU emulation — then pushed by digest and merged into
a single manifest list by a follow-up `merge` job, so the tag is never updated
with a single-arch image.

## Gotchas

- **Debian bullseye is EOL**: the Dockerfile repoints apt to `archive.debian.org`
  and disables `Acquire::Check-Valid-Until`; otherwise bullseye-security 404s and
  every `apt-get install` fails.
- **PHP is built from source** (not `FROM php:8.0-fpm-bullseye`): official 8.0.30
  tarball pinned by `PHP_SHA256`, then `docker-php-source extract` +
  `patch -p1 --fuzz=0`.
- **Three stages**: `base` (archive + no-debian-php pin), `builder` (source,
  patch, toolchain, static extensions), `runtime` (only `/usr/local` payload +
  runtime libs). The runtime stage must never gain a compiler or PHP source; that
  is what keeps the image near the official size.
- **Extensions are static by default**: `scripts/static-extensions.conf` maps
  each extension to its configure flags, and `scripts/build-php-static.sh`
  stages PECL sources into `/usr/src/php/ext/<name>` *before* `./buildconf
  --force` so they are linked into the binaries. Adding an extension means
  editing the conf/manifest, installing its build/runtime libs and rebuilding —
  there is no `extension=.so` at runtime. Full steps: `scripts/README.md`.
- **OPcache must stay shared**: PHP < 8.5's `ext/opcache/config.m4` forces
  `ext_shared=yes`. `opcache.so` + `zend_extension=opcache.so` are required.
  sodium also stays shared to match the official image.
- **PECL tarballs are pinned, not installed by name**: pecl.php.net answers
  PEAR's REST metadata request with a gzip body that PEAR cannot parse, so
  `pecl install <name>` fails with `Package "<name>" Version "<v>" does not have
  REST xml available` for every PECL package. The `name version sha256` table in
  `scripts/build-php-static.sh` is the single source of truth; it downloads each
  tarball and verifies the SHA256.
- **zstd uses the system libzstd**: `zstd-0.18.0` bundles its own zstd by
  default; the static build passes `--with-libzstd` to avoid duplicate ZSTD
  symbols with redis (which links libzstd as well).
- **redis keeps LZF/LZ4/ZSTD, using system libs**: `--enable-redis-lzf
  --with-liblzf --enable-redis-lz4 --with-liblz4 --enable-redis-zstd`. The
  bundled `ext/redis/liblzf` path breaks in-tree (`lzf.h` is only found via the
  phpize `$srcdir`), so LZF links Debian's `liblzf` (`liblzf-dev` build,
  `liblzf1` runtime).
- **runtime apt list must stay in sync** with
  `ldd /usr/local/bin/php /usr/local/sbin/php-fpm /usr/local/lib/php/extensions/*/*.so`.
  Missing a runtime lib only shows up as a `php-fpm` startup failure; the check is
  in `docs/plans/php-8.0-static-extensions.md` §10.2.
- **`docker-php-ext-install` is gone**: the runtime image has no toolchain.
  Use `docker build --target builder` and `docker-php-ext-static-install <ext>`
  (interface identical to the 7.4 branch). `docker-php-clean source|deps|all`
  cleans build inputs; remember Docker layers are immutable, so it only helps
  inside the builder stage.
- **LF line endings are mandatory** for `docker-php-scripts/*` (no extension),
  `scripts/*`, `*.sh`, `*.ini`, `*.patch` and `*.conf`; `.gitattributes`
  enforces this (plus `*.md` for readable diffs). `static-extensions.conf` is
  TAB-separated — a CRLF checkout puts `\r` into every configure flag.
- **CVE marker**: the image carries
  `/usr/local/etc/php/cve-2026-109618-109619.patched` with both CVE IDs, the
  40-hex commit and the branch declaration. Two more markers are visible on
  `phpinfo()`: `conf.d/zz-cve-2026-109618-109619.ini` (comment-only, listed under
  "Additional .ini files parsed") and the `PHP_CVE_PATCHES` env var
  (`CVE-2026-109618,CVE-2026-109619`, visible because `variables_order` has `E`).
- The patch is verified to apply to 8.0.30 with zero fuzz and to reproduce the
  upstream branch byte-for-byte; do not hand-edit it.
- Timezone is hardcoded to `Asia/Hong_Kong` in the Dockerfile.
- `pm.max_requests = 5` in FPM config (intentionally low — forces frequent worker
  recycling).
- Entrypoint sets `umask 0000` (world-writable files).
- Composer is a pinned 2.11.2 phar (`ADD --checksum`), not something installed by
  an extension installer.
- JIT config lives in `opcache.ini` (COPY to `/usr/local/etc/php/conf.d/`),
  **not** via `php_admin_value` in FPM pool config (JIT directives like
  `opcache.jit_buffer_size` are `INI_SYSTEM` and don't work reliably through
  `php_admin_value`).
- PHP 8.0 JIT defaults: `opcache.jit=tracing` and `opcache.jit_buffer_size=0`
  (disabled). Must set buffer size to enable JIT. On arm64 PHP 8.0's OPcache JIT
  is disabled by configure (`JIT not supported by host architecture`); this is
  unchanged from the previous image.

## Documentation rules

- Current design/verification documents live in `docs/plans/`; add an entry to
  `docs/README.md`.
- Superseded documents move to `docs/archive/` with a
  `⛔ 此文件已被 <new doc> 取代` notice, and their inbound links are updated.
- Keep the header block (`分支 / 目標鏡像 / 狀態 / 相關`) and back-fill measured
  verification results after implementation.
