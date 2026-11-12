# Agent Notes — php-docker

Docker image repo for a PHP 7.4 FPM runtime (`mmhk/php-docker`). Not an
application repo: there is no test framework or linter. Verification means
building the image and running a container. The only CI is the release build in
`.github/workflows/release.yml`.

## Branch model (read before editing)

- Each PHP version / variant is a **separate branch**: `5.6-fpm`, `7.0-cli`,
  `7.0-fpm`, `7.2-fpm`, `7.4-fpm` (current), `8.0-fpm`, `8.1-fpm` … `8.4-fpm`,
  plus `caddy-*`, `nginx-ws-fpm`, etc. `main` is not the deploy target.
- Make changes on the branch matching the image tag you are shipping. Do **not**
  blindly cherry-pick across branches: base images, apt handling and extension
  strategy differ between branches.
- Tags are published per branch, e.g. `mmhk/php-docker:7.4-fpm` (matches
  `docker-compose.yml`).

## Architecture (7.4-fpm)

The Dockerfile is multi-stage:

| Stage | Purpose |
|---|---|
| `base` | `debian:bullseye-slim` + archive apt sources + no-debian-php pin |
| `builder` | PHP 7.4.33 source + CVE patch + statically linked extensions; keeps source/toolchain/`.a` intermediates |
| `runtime` | apt runtime libraries + selected files copied from builder; no compiler, no PHP source |

- The final image is the default build target. The builder is only reachable with
  `docker build --target builder`.
- Extensions (except OPcache and sodium) are **compiled into** `php` /
  `php-fpm`; they have no `.so` and no `extension=` ini.
- OPcache cannot be static on PHP 7.4 (`ext/opcache/config.m4` forces
  `ext_shared=yes`), so `opcache.so` / its ini remains. Sodium stays shared to
  match the upstream image.
- The final image intentionally does **not** contain `/usr/src/php`, the PHP
  tarball, `install-php-extensions`, or the compiler.

### Script layout

`scripts/` — build-time inputs, copied into the builder:

- `build-php-static.sh`: downloads/verifies PHP + CVE patch + PECL tarballs,
  stages PECL sources in `ext/`, runs `buildconf`/`configure`/`make`/`install`,
  writes the OPcache/sodium ini, and verifies `php -m`.
- `static-extensions.conf`: extension → configure-flags table shared by the
  build script and the static installer.

`docker-php-scripts/` — vendored helpers copied to `/usr/local/bin` in the
builder:

- `docker-php-source`: extract/delete `/usr/src/php` (still used by the build).
- `docker-php-ext-enable`: writes the OPcache/sodium ini during build.
- `docker-php-ext-static-install`: adds a static extension by re-running
  `buildconf`/`configure`/`make`; **builder only**.
- `docker-php-ext-static-remove`: removes an entry from the static manifest and
  rebuilds; builder only.
- `docker-php-clean`: `source` / `deps` / `all` cleanup; useful in the builder,
  but remember Docker layers are immutable — cleanup in a later RUN does not
  shrink the image.

## Build, verify, ship

```bash
# final image
docker build -t mmhk/php-docker:7.4-fpm .

# builder image (source + toolchain, for static extension changes)
docker build --target builder -t mmhk/php-docker:7.4-fpm-builder .

# multi-arch release
docker buildx build --platform linux/amd64,linux/arm64 \
  -t mmhk/php-docker:7.4-fpm --push .
```

Runtime smoke checks (scripts are bind-mounted because they are excluded from
the build context):

```bash
docker run --rm -v "$PWD/tests/verify-ca-bundle.php:/verify.php:ro" \
  mmhk/php-docker:7.4-fpm php /verify.php
docker run --rm -v "$PWD/test-ssl.php:/test-ssl.php:ro" \
  mmhk/php-docker:7.4-fpm php /test-ssl.php
```

`tests/verify-ca-bundle.php` exits non-zero on failure, makes live HTTPS calls,
and needs outbound network access.

## Extension model

Static list (18): `bcmath bz2 exif ffi gd gettext mysqli pdo_mysql soap sockets
zip snmp shmop memcached imagick mcrypt redis timezonedb`.
Shared: `opcache`, `sodium`. Composer is a pinned phar (`2.11.2`).

To add or change an extension:

1. Add/update its row in `scripts/static-extensions.conf`.
2. Add the PECL source staging (version + SHA256) in
   `scripts/build-php-static.sh` if it is not bundled with PHP.
3. Add the `-dev` build dependency in the builder apt list **and** the runtime
   library in the runtime apt list.
4. Rebuild the final image and confirm `php -m`.

In the builder, a one-off add is:

```bash
docker run --rm mmhk/php-docker:7.4-fpm-builder \
  docker-php-ext-static-install <ext>
```

This only works while `/usr/src/php`, `.docker-configure-base`, the manifest and
the compiler are present. PECL sources must already exist under
`/usr/src/php/ext/<name>`. The script does not resolve apt/PECL dependencies.

## Dockerfile conventions

- Base is `debian:bullseye-slim` (not `php:7.4-fpm-bullseye`). Bullseye is EOL,
  so apt sources are rewritten to `archive.debian.org` and
  `Acquire::Check-Valid-Until "false"` is set. Keep this or apt breaks.
- PHP is built from the official 7.4.33 tarball + the CVE backport patch; both
  are SHA256-pinned. PECL tarballs are pinned the same way.
- FPM tuning (`pm.max_children`, `pm.max_requests=5`, error_log to
  `/proc/self/fd/2`, etc.) is done with `sed` against upstream `.conf` files, not
  a copied config. Change those `sed` expressions rather than adding a new conf.
- `USER www-data:www-data` with `entrypoint.sh` (`umask 0000`, then `exec "$@"`).
  The default container has no root shell; use `docker run --user root …` for
  apt/debug.
- The image exposes `9000`; `docker-compose.yml` deliberately has no
  ports/volumes and builds for amd64+arm64.
- `.dockerignore` excludes `tests/`, `coraza/`, `README.md`, `LICENSE`,
  `.gitignore`, `docker-compose.yml`; only `file-upload.conf`, `ca-bundle.ini`,
  and `entrypoint.sh` are copied in.
- The runtime stage copies only selected builder paths (`/usr/local/bin/php`,
  Composer, `php-fpm`, `/usr/local/lib/php`, `/usr/local/etc`, CA bundle). Do not
  copy `/usr/local` wholesale or the source/toolchain size advantage is lost.

## CA bundle (current behavior)

- PHP's trust store is **not** the system bundle. The builder downloads
  `https://curl.se/ca/cacert.pem` into
  `/usr/local/share/ca-certificates/cacert.pem`; the runtime stage copies that
  path. `ca-bundle.ini` pins `openssl.cafile` and `curl.cainfo` to it.
  `/etc/ssl/certs/ca-certificates.crt` is intentionally untouched.
- The download is the mutable `cacert.pem` with no checksum.
  `docs/plans/2026-11-09-emudhra-ca-bundle-fix.md` proposes a fixed-date file
  plus SHA256 verification; that is **not implemented**. Trust the Dockerfile,
  not the plan docs.
- Any CA change must update the builder download layer, the runtime copy and
  `ca-bundle.ini` paths, then re-run the verification script in a built image.

## Documentation map

- `docs/plans/2026-11-12-php-7.4-static-extensions.md` — current architecture,
  script design, task status and local verification results.
- `docs/plans/php-7.4-cve-2026-109618-109619-patch.md` — CVE patch source and
  design; its old extension-install steps are superseded.
- `docs/plans/2026-11-09-emudhra-ca-bundle-fix.md` and
  `docs/2026-11-11-emudhra-ca-bundle-verification.md` — CA history; check the
  Dockerfile for actual behavior.
- `docs/plans/php-7.4-extension-install.md` — historical IPE/PECL tarball
  design, superseded by static embedding.
- `docs/plans/2026-11-11-7.4-fpm-native-arm64-ci.md` — arm64 CI background.
- `docs/2026-10-23-caddy-websocket-over-http2-502.md` — unrelated incident note.

## Change discipline

- Prefer the smallest incremental change. Extend the existing mechanisms
  (`scripts/static-extensions.conf`, `build-php-static.sh`, the Dockerfile sed
  lines) instead of adding a parallel config system.
- Do not create a new README/summary doc for a change. Put notes in `docs/` or
  edit an existing file; keep this AGENTS.md and README aligned with the code.
- Don't build multi-arch images, tag, or push unless the user asks. For normal
  changes: build locally and run the smoke script for the area you touched.
- Keep the runtime stage lean: build dependencies belong in the builder stage;
  runtime libraries belong in the runtime apt list.

## Planning docs (existing convention)

Plans live at `docs/plans/YYYY-MM-DD-<topic-slug>.md`. Any AI-authored plan must
open with:

```markdown
> **AI 生成聲明 (AI-Generated Declaration)**：本文件由 AI 依需求分析自動生成，內容尚未經人類審核。僅供參考，需人類 review + confirm 後方可執行。
> **Review Status**: ⚪ Pending
> **Reviewed By**: (人工填寫姓名/日期)

**Created**: YYYY-MM-DD
**Status**: 🟡 In Progress
**Priority**: High | Medium | Low
**Human Review**: ⚪ Pending
```

followed by `Background & Goals`, `Design Decisions`, a `Tasks` table,
`Review Log`, `Verification`, and `Risks & Mitigations` / `Rollback`.

- Never set `Review Status` to ✅ or `Status` to Complete yourself; only a human
  reviewer confirms.
- An unconfirmed plan is **not** an executable spec. Verify claims against the
  Dockerfile and scripts before implementing from a doc.

## Commits and language

- Version control is **Git** (unlike the separate `insurance_quotation` repo,
  which uses SVN — do not copy its commit workflow here).
- Recent branches use Conventional Commit prefixes with Chinese subjects, e.g.
  `feat(docker): 擴充改為靜態內嵌並以多階段建置縮小映像`.
- Docs and commit messages are in Chinese. Keep the language of the file you are
  editing rather than translating it (README is Simplified; some docs are
  Traditional).

## Definition of done

1. `docker build -t mmhk/php-docker:7.4-fpm .` completes.
2. Run the smoke script for the touched area; when CA / OpenSSL / curl config
   changes, run both CA scripts.
3. For extension changes, confirm the module appears in `php -m`, the extension
   dir contains only the expected shared modules, and `php-fpm -t` passes.
4. For a new static extension, also verify it in the builder with
   `docker-php-ext-static-install`.
5. For CA changes, `php -i | grep -E "openssl.cafile|curl.cainfo"` inside the
   image must report `/usr/local/share/ca-certificates/cacert.pem`.

## Files to ignore / not commit

- `tests/` and `coraza/` are gitignored. `coraza/` is a large vendored OWASP CRS
  tree; `tests/` scripts are local-only. Do not add them, and remember the build
  context excludes them.
- `docs/` holds incident/design notes. Some docs are historical or aspirational;
  the static-extension plan and the Dockerfile are the current source of truth.
- `.gitattributes` forces LF for `*.sh`; the Dockerfile also strips trailing
  `\r` from `entrypoint.sh`. Preserve both when editing shell files on Windows.
