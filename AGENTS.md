# Agent Notes — php-docker

Docker image repo for a PHP-FPM runtime (`mmhk/php-docker`). Not an application repo: there is no test framework, linter, or CI. Verification means building the image and running a container.

## Branch model (read before editing)

- Each PHP version / variant is a **separate branch**: `5.6-fpm`, `7.0-cli`, `7.0-fpm`, `7.2-fpm`, `7.4-fpm` (current), `8.0-fpm`, `8.1-fpm` … `8.4-fpm`, plus `caddy-*`, `nginx-ws-fpm`, etc. `main` is not the deploy target.
- Make changes on the branch matching the image tag you are shipping. Do **not** blindly cherry-pick across branches: base images and apt handling differ (e.g. `8.0-fpm` lacks the bullseye archive-source fix that `7.4-fpm` has).
- Tags are published per branch, e.g. `mmhk/php-docker:7.4-fpm` (matches `docker-compose.yml`).

## Build, verify, ship

```bash
docker build -t mmhk/php-docker:7.4-fpm .
docker buildx build --platform linux/amd64,linux/arm64 -t mmhk/php-docker:7.4-fpm --push .
```

Runtime smoke checks (the scripts are bind-mounted because they are excluded from the build context):

```bash
docker run --rm -v "$PWD/tests/verify-ca-bundle.php:/verify.php:ro" mmhk/php-docker:7.4-fpm php /verify.php
docker run --rm -v "$PWD/test-ssl.php:/test-ssl.php:ro" mmhk/php-docker:7.4-fpm php /test-ssl.php
```

`tests/verify-ca-bundle.php` exits non-zero on failure and makes live HTTPS calls to google.com — it needs outbound network access.

## Dockerfile conventions

- Base is `php:7.4-fpm-bullseye`. Bullseye is EOL, so apt sources are rewritten to `archive.debian.org` and `Acquire::Check-Valid-Until "false"` is set. Keep this when touching the apt layer or builds break.
- Extensions are installed via `mlocati/php-extension-installer` in one `install-php-extensions` list. Adding an extension means editing that list **and** the README extension table.
- FPM tuning (`pm.max_children`, `pm.max_requests=5`, error_log to `/proc/self/fd/2`, etc.) is done with `sed` against upstream `.conf` files, not a copied config. Change those `sed` expressions rather than adding a new conf.
- `USER www-data:www-data` with `entrypoint.sh` (`umask 0000`, then `exec "$@"`). The default container has no root shell; use `docker run --user root …` for apt/debug.
- The image exposes `9000`; `docker-compose.yml` deliberately has no ports/volumes and builds for amd64+arm64.
- `.dockerignore` excludes `tests/`, `coraza/`, `README.md`, `LICENSE`, `.gitignore`, `docker-compose.yml`; only `file-upload.conf`, `ca-bundle.ini`, and `entrypoint.sh` are copied in.

## CA bundle (current behavior, not the plan docs)

- PHP's trust store is **not** the system bundle. `Dockerfile` downloads `https://curl.se/ca/cacert.pem` at build time into `/usr/local/share/ca-certificates/cacert.pem`; `ca-bundle.ini` pins `openssl.cafile` and `curl.cainfo` to it (copied to `/usr/local/etc/php/conf.d/ca-bundle.ini`). `/etc/ssl/certs/ca-certificates.crt` is intentionally untouched.
- The download is the mutable `cacert.pem` with no checksum. `docs/plans/2026-11-09-emudhra-ca-bundle-fix.md` proposes a fixed-date file plus SHA256 verification; that is **not implemented**. Trust the Dockerfile, not the docs.
- Any CA change must update both the Dockerfile download layer and `ca-bundle.ini` paths, then re-run the verification script in a built image.

## Change discipline

- Prefer the smallest incremental change. This repo has no application layer to justify new abstractions, interfaces, or config files — extend the existing mechanism (`sed` edits in the Dockerfile, `ca-bundle.ini`, `entrypoint.sh`) instead of adding a parallel one.
- Do not create a new README/summary doc for a change. The CA work already left overlapping artifacts (`README.md`, `CA_BUNDLE_QUICKREF.md`, `CA_BUNDLE_UPDATE_PLAN.md`, `IMPLEMENTATION_SUMMARY.md`, `VERIFICATION_REPORT.md`); put new notes in `docs/` or edit an existing file.
- Don't build multi-arch images, tag, or push unless the user asks. For normal changes: build locally and run only the smoke script for the area you touched.

## Planning docs (existing convention)

Plans live at `docs/plans/YYYY-MM-DD-<topic-slug>.md` (see `docs/plans/2026-11-09-emudhra-ca-bundle-fix.md`). Any AI-authored plan must open with:

```markdown
> **AI 生成聲明 (AI-Generated Declaration)**：本文件由 AI 依需求分析自動生成，內容尚未經人類審核。僅供參考，需人類 review + confirm 後方可執行。
> **Review Status**: ⚪ Pending
> **Reviewed By**: (人工填寫姓名/日期)

**Created**: YYYY-MM-DD
**Status**: 🟡 In Progress
**Priority**: High | Medium | Low
**Human Review**: ⚪ Pending
```

followed by `Background & Goals`, `Design Decisions`, a `Tasks` table, `Review Log`, `Verification`, and `Risks & Mitigations` / `Rollback`.

- Never set `Review Status` to ✅ or `Status` to Complete yourself; only a human reviewer confirms.
- An unconfirmed plan is **not** an executable spec. This repo proves why: the CA plan specifies a fixed-date `cacert-YYYY-MM-DD.pem` with SHA256 verification, but the Dockerfile actually downloads a mutable `cacert.pem` with no checksum. Verify against code before implementing from a doc.

## Commits and language

- Version control is **Git** (unlike the separate `insurance_quotation` repo, which uses SVN — do not copy its commit workflow here).
- Recent branches use Conventional Commit prefixes with Chinese subjects, e.g. `feat(docker): 更新Dockerfile配置并添加发布工作流` / `refactor(docker): opcache 改用獨立 ini 配置`. Older commits on this branch are plain Chinese descriptions. Match the style of the branch you are on.
- Docs and commit messages are in Chinese (most are Simplified; `docs/2026-10-23-caddy-websocket-over-http2-502.md` is Traditional). Keep the language of the file you are editing rather than translating it.

## Definition of done

1. `docker build -t mmhk/php-docker:7.4-fpm .` completes.
2. Run the smoke script for the touched area; when CA / OpenSSL / curl config changes, run both.
3. For CA changes, `php -i | grep -E "openssl.cafile|curl.cainfo"` inside the image must report `/usr/local/share/ca-certificates/cacert.pem`.
4. For a new extension, confirm it appears in `php -m` and add it to the README table.

## Files to ignore / not commit

- `tests/` and `coraza/` are gitignored. `coraza/` is a large vendored OWASP CRS tree; `tests/` scripts are local-only. Do not add them, and remember the build context excludes them.
- `docs/` holds incident/design notes (e.g. the Caddy HTTP/2 WebSocket 502 analysis). Some docs are aspirational or describe other branches' images; verify claims against the Dockerfile before acting.
- `README.md` is stale: it advertises `mmhk/php-docker:8-fpm` and an incomplete extension list (missing `shmop`, `ffi`) although this branch builds 7.4. Do not use it as the source of truth for the image tag.
- `.gitattributes` forces LF for `*.sh`; the Dockerfile also strips trailing `\r` from `entrypoint.sh`. Preserve both when editing shell files on Windows.
