# PHP 8.0 擴充靜態內嵌（static embed）方案與實作

> 分支：`8.0-fpm`　｜　目標鏡像：`mmhk/php-docker:8.0-fpm`
> 狀態：🟢 已實作；本機 amd64 建置與驗證通過（arm64 CI 待 `v*` tag）
> 參考實作：`7.4-fpm` 分支 `docs/plans/2026-11-12-php-7.4-static-extensions.md`
> （同一 repo 已用相同手法完成：1.53GB → 463MB，20 個 `.so` → 2 個）
> 相關：`docs/plans/php-8.0-cve-2026-109618-109619-patch.md`、
> `docs/archive/php-8.0-extension-install.md`（歷史：被本方案取代）

---

## 1. 背景與目標

### 1.1 背景

本分支為了 CVE-2026-109618 / CVE-2026-109619 已從 PHP **8.0.30** 原始碼重新編譯
（`php:8.0-fpm-bullseye` 已 EOL，binary 無法事後 patch）。但目前擴充仍走第二條路：

1. Dockerfile 最前面安裝 `$PHPIZE_DEPS`（gcc / g++ / make / autoconf…）並**留在 runtime**；
2. `scripts/install-extensions.sh` 用 `install-php-extensions` 逐一 `phpize` 出 **24 個 `.so`**；
3. 每個 `.so` 都配一個 `docker-php-ext-*.ini`，啟動時逐一 `dlopen`。

同一批 extension source 其實已經被 PHP 建置流程看過一次，卻又各自重編一次；
`$PHPIZE_DEPS` 也一直是 image 裡最大的單一 layer。

### 1.2 目標

1. 把可靜態編譯的 **22 個擴充**直接編進 `php` / `php-fpm` binary，
   runtime 不再需要對應 `.so` 與 `extension=` ini。
2. 只保留 **`opcache.so`**（PHP 8.0 硬限制）與 **`sodium.so`**（貼近官方行為）。
3. 改成 **multi-stage**：builder 內下載 / patch / 編譯 / 暫存原始碼，
   runtime 只 COPY `/usr/local` 的執行期產物，**不含編譯器、不含 PHP 原始碼**。
4. 保留 `docker-php-ext-static-install` / `-remove` 供 **builder stage** 追加擴充；
   新增 `docker-php-clean` 支援 `source` / `deps` / `all`。
5. 功能與版本**完全不變**：
   - PHP 8.0.30 + 同一個 CVE 補丁（SHA256 不變）；
   - PECL 版本不變：memcached 3.4.0 / imagick 3.8.1 / mcrypt 1.0.9 / redis 6.0.2 /
     timezonedb 2026.5 / zstd 0.18.0；
   - gd（JPEG/PNG/WebP/XPM/FreeType）、redis（LZF/LZ4/ZSTD）、memcached（JSON/SASL/Session）、
     imagick（ImageMagick 6）、gmp、pgsql、pdo_pgsql、zip、snmp、ffi 全部保留。

### 1.3 非目標

- 不改 PHP 版本、不改 CVE 補丁內容、不改 PECL 版本。
- 不新增 / 移除擴充清單（只改「編譯方式」）。
- 不在 final image 保留 in-container 編譯能力（取捨見 §8）。
- 不把 `sodium` 一併靜態（第一階段維持 shared，見 §12）。

---

## 2. 現況實測（2026-11-12，本機 amd64）

| 項目 | 實測 |
|---|---|
| `docker image ls --tree`（amd64 disk usage） | **800MB**（content size 198MB） |
| 同一 tag 的 arm64 disk usage | 740MB（本地 index 為 amd64+arm64） |
| `php -m` 模組數 | **59**（含 `Zend OPcache`） |
| extension dir（`no-debug-non-zts-20200930`） | **24 個 `.so`**，合計約 6 MB |
| 目前載入的 ini | 24 個擴充 ini（23 個 `docker-php-ext-*.ini` + `xx-php-ext-memcached.ini`）+ `opcache.ini` + `ca-bundle.ini` + `docker-fpm.ini` + `zz-cve*.ini` |
| `/usr/src/php.tar.xz` | 11MB（刻意保留給 `docker-php-source extract`） |
| `/usr/local/lib/php` | 14MB（含 pear / phpize headers） |
| `php` / `php-fpm` binary | 17MB / 17MB |
| merged filesystem `/` | 568MB |
| 已安裝套件 `Installed-Size` 合計 | 約 570MB |
| 最大 layer | `$PHPIZE_DEPS` apt layer **284MB**、擴充安裝 layer **129MB**、PHP 建置 layer 83.9MB |

### 2.1 為什麼是 800MB

- `$PHPIZE_DEPS`（284MB）與 gcc/g++/make 等編譯器一直留在 runtime；
- `install-php-extensions` 的 129MB layer：24 個 `.so` 只佔 6MB，其餘是 Imagick /
  ghostscript / snmp / pgsql 等 persistent 依賴，以及被 PEAR registry 佔用的空間；
- 11MB 的 `php.tar.xz` 與 `$PHPIZE_DEPS` 都是「下載 / 安裝在舊 layer，之後刪不掉」。

### 2.2 官方與 7.4 分支對照

| 版本 | 做法 | amd64 大小 |
|---|---|---|
| 官方 `php:8.0-fpm-bullseye` | 大部分擴充靜態，只有 opcache / sodium shared | 約 450~480MB（未實測） |
| 本 repo `7.4-fpm`（已完成） | 18 擴充靜態 + multi-stage | **463MB**（自 1.53GB） |
| 本 repo `8.0-fpm`（現況） | 24 個 `.so` + IPE + `$PHPIZE_DEPS` | **800MB** |

> 也就是說：8.0 目前比「官方做法」多背了約 340MB，主因就是 `$PHPIZE_DEPS` 與
> in-container 編譯流程；靜態內嵌 + multi-stage 可以直接回到官方量級。

---

## 3. 可行性查證（已逐檔查證，非推測）

### 3.1 PHP 的靜態擴充機制

- `ext/<name>/config.m4` 最後呼叫 `PHP_NEW_EXTENSION(<name>, <sources>, $ext_shared, …)`。
  in-tree build 只要 configure 時**不給 `=shared`**，`$ext_shared` 就是 `no`，
  該擴充會進 `EXT_STATIC`，由 `build/genif.sh` 產生 `main/internal_functions.c`，
  在 `php_module_startup()` 時註冊。
- PHP 8.0.30 的 `PHP_NEW_EXTENSION`（`build/php.m4`）在 `$3 != shared/yes` 時
  確實走 Static module 分支，支援 `.c` / `.S`（zstd 需要）等副檔名。
- PECL 套件只要把 tarball 解到 `/usr/src/php/ext/<name>`，再 `./buildconf --force`：
  `build/config-stubs` 會對每個 `ext/*/config.m4` 產生對應的
  `PHP_EXT_SRCDIR` / `PHP_EXT_BUILDDIR` 定義後 `sinclude`，
  所以連 zstd 這種用 `PHP_EXT_SRCDIR()/zstd/lib/...` 的寫法在 in-tree 也能解析。

### 3.2 OPcache 是硬限制（PHP 8.0 已實查）

`ext/opcache/config.m4`（PHP-8.0.30）開頭明確寫著：

```m4
if test "$PHP_OPCACHE" != "no"; then
  dnl Always build as shared extension
  ext_shared=yes
```

PHP 8.5 之前 OPcache 只能 shared，因此 `opcache.so` 與
`zend_extension=opcache.so` ini 必須保留。**這不是本方案能繞過的部分。**

### 3.3 逐擴充可行性

| 擴充 | 來源 | 靜態可行性 | 備註 |
|---|---|---|---|
| bcmath bz2 exif ffi gettext gmp mysqli pdo_mysql pdo_pgsql pgsql soap sockets zip snmp shmop gd | bundled 8.0.30 | ✅ | config.m4 皆為 `$ext_shared` |
| memcached 3.4.0 | PECL | ✅ | 3.4.0 config.m4 為 `PHP_NEW_EXTENSION(..., $ext_shared)` |
| imagick 3.8.1 | PECL | ✅ | 有 in-tree / `--with-imagick` 分支 |
| mcrypt 1.0.9 | PECL | ✅ | 7.4 分支已驗證同一版本 |
| redis 6.0.2 | PECL | ✅ | LZF/LZ4/ZSTD 均由 config.m4 決定 |
| timezonedb 2026.5 | PECL | ✅ | `ZEND_MOD_REQUIRED("date")`，需驗證啟動順序 |
| zstd 0.18.0 | PECL | ✅ 但**路徑特殊** | in-tree 建議改用系統 `libzstd`，見 §5.3 |
| opcache | bundled | ❌ 強制 shared | 保留 `.so` |
| sodium | bundled | ✅ 可靜態 | 本階段**維持 shared**（官方同款） |

### 3.4 PECL 在 in-tree 的兩個「非典型」點

1. **zstd 0.18.0**：預設把自帶的 zstd 1.5.x 原始碼一起編（`HAVE_BUNDLED_ZSTD`）。
   in-tree 下 `PHP_EXT_SRCDIR()` 會被 `config-stubs` 正確展開，`.S` 檔也支援；
   但靜態連結時 binary 內會同時有「自帶 zstd」與 redis 依賴的「系統 libzstd 1.4.8」，
   產生同符號競合風險。**建議 zstd 也改用系統 libzstd（`--with-libzstd`）**，
   與 redis 統一，行為等價（`zstd_compress` API 不變）。
2. **redis 6.0.2 的 LZF**：`--enable-redis-lzf` 預設用自帶 `ext/redis/liblzf`。
   **已實測失敗**（2026-11-12 本機 build）：
   `ext/redis/library.c:19:10: fatal error: lzf.h: No such file or directory`，
   因為 in-tree 的 `$srcdir` 指向 PHP 根目錄，`PHP_ADD_INCLUDE($srcdir/liblzf)`
   展開成 `/usr/src/php/liblzf`（不存在），而 `library.c` 用的是 `#include <lzf.h>`。
   因此本方案**改用系統 liblzf**：`--with-liblzf` + `liblzf-dev` / `liblzf1`
   （bullseye 3.6-3，`liblzf.pc` 提供 `-llzf`，已確認存在）。

### 3.5 bullseye archive 編譯 / 執行期套件可用性（apt-cache 實查）

所有需要的套件都存在於 `archive.debian.org` bullseye：

| 用途 | 套件（build） | 版本 | runtime |
|---|---|---|---|
| bz2 | `libbz2-dev` | 1.0.8-4 | `libbz2-1.0` |
| ffi | `libffi-dev` | 3.3-6 | `libffi7` |
| gd | `libfreetype6-dev` `libjpeg62-turbo-dev` `libpng-dev` `libwebp-dev` `libxpm-dev` | 2.10.4 / 2.0.6 / 1.6.37 / 0.6.1 / 3.5.12 | `libfreetype6` `libjpeg62-turbo` `libpng16-16` `libwebp6` `libxpm4` |
| zip | `libzip-dev` | 1.7.3-1 | `libzip4` |
| snmp | `libsnmp-dev` | 5.9+dfsg-4+deb11u3 | `libsnmp40` |
| mcrypt | `libmcrypt-dev` | 2.5.8-3.4+b1 | `libmcrypt4` |
| imagick | `libmagickwand-dev`（IM6） | 8:6.9.11.60+dfsg-1.3+deb11u16 | `libmagickwand-6.q16-6` 等 |
| memcached | `libmemcached-dev` `libsasl2-dev` | 1.0.18-4.2 / 2.1.27 | `libmemcached11` `libsasl2-2` |
| redis | `liblz4-dev` `libzstd-dev` `liblzf-dev` | 1.9.3 / 1.4.8 / 3.6 | `liblz4-1` `libzstd1` `liblzf1` |
| gmp | `libgmp-dev` | 6.2.1 | `libgmp10` |
| pgsql / pdo_pgsql | `libpq-dev` | 13.23 | `libpq5` |
| zstd | —（改用系統 `libzstd-dev`） | 1.4.8 | `libzstd1` |
| sodium | `libsodium-dev`（既有） | 1.0.18 | `libsodium23` |

> 已用 `apt-cache policy` 在 bullseye archive 容器內逐一確認 candidate，非紙上推測。

### 3.6 Docker layer 的關鍵限制

layer 是 immutable：在後續 `RUN` 刪除前一層的檔案，**image 不會變小**。
因此「下載 + 編譯 + 清除」必須在**同一個 stage / 同一條 `RUN`**，
或用 multi-stage 讓 builder 整個不進 final image。本方案採後者。

---

## 4. 方案比較

| 方案 | 內容 | 優點 | 缺點 | 結論 |
|---|---|---|---|---|
| **A. multi-stage + 全靜態** | builder 編 PHP＋22 擴充；runtime 只 COPY `/usr/local`；opcache/sodium 維持 `.so` | 一次編譯、runtime 最乾淨、可真正縮小 layer、builder 保留 static-install 能力 | 需要自管 PECL 靜態編譯與 runtime 套件清單 | ✅ **建議** |
| B. bundled 靜態、PECL 維持 `.so` | 只內嵌 16 個 bundled | 風險較低 | 仍有 6 個 PECL `.so`、仍需 IPE / source tar、節省有限 | 次選（可作為階段 1） |
| C. 單階段、同 RUN 清除 | 保留單一 stage，build deps 在同 RUN 安裝＋purge | Dockerfile 變動小 | 失去 builder 的重編能力；PECL 靜態仍需 source；除錯較差 | 不採用 |
| D. 維持現狀 | 不改 | 無風險 | 800MB、24 個 `.so`、編譯器長駐 | ❌ |

**建議採 A**，與 7.4 分支保持同一套架構與腳本介面，降低跨分支維護成本。

---

## 5. 目標擴充清單與 configure 對照

### 5.1 清單

靜態內嵌（22）：

```
bcmath bz2 exif ffi gd gmp gettext imagick mcrypt memcached
mysqli pdo_mysql pdo_pgsql pgsql redis shmop snmp soap sockets
timezonedb zip zstd
```

保留 shared（2）：

```
opcache   # PHP 8.0 強制 shared
sodium    # 貼近官方行為；第一階段不內嵌
```

> `php -m` 應與現行 image 的 59 個模組**完全一致**（含 `Zend OPcache`）。

### 5.2 `scripts/static-extensions.conf`（預計內容）

```
# 靜態內嵌擴充對照表：<ext-name><TAB><configure flags>
# 由 scripts/build-php-static.sh 與 docker-php-ext-static-install 共用。
bcmath	--enable-bcmath
bz2	--with-bz2
exif	--enable-exif
ffi	--with-ffi
gd	--enable-gd --with-webp --with-jpeg --with-xpm --with-freetype
gmp	--with-gmp
gettext	--with-gettext
imagick	--with-imagick
mcrypt	--with-mcrypt
memcached	--enable-memcached --with-libmemcached-dir=/usr --with-zlib-dir=no --with-system-fastlz=no --enable-memcached-json --enable-memcached-sasl --enable-memcached-session --enable-memcached-protocol=no
mysqli	--with-mysqli=mysqlnd
pdo_mysql	--with-pdo-mysql=mysqlnd
pdo_pgsql	--with-pdo-pgsql
pgsql	--with-pgsql
redis	--enable-redis --enable-redis-lzf --with-liblzf --enable-redis-lz4 --with-liblz4 --enable-redis-zstd
shmop	--enable-shmop
snmp	--with-snmp
soap	--enable-soap
sockets	--enable-sockets
timezonedb	--enable-timezonedb
zip	--with-zip
zstd	--enable-zstd --with-libzstd
```

> 全部 flag 已逐一對過 PHP 8.0.30 與各 PECL tarball 的 `config.m4`；
> 因 base args 含 `--enable-option-checking=fatal`，拼錯會直接 build fail（這是好事）。

### 5.3 與現行 IPE 行為的對齊（重點差異）

| 擴充 | 現行（IPE）實際行為 | 本方案 | 說明 |
|---|---|---|---|
| gd | `--enable-gd --with-webp --with-jpeg --with-xpm --with-freetype` | 相同 | 8.0 沒有 `--with-avif` |
| redis | LZF（自帶）＋LZ4（系統）＋ZSTD（系統）；igbinary/msgpack off | LZF/LZ4/ZSTD 全用系統 lib | 自帶 LZF 在 in-tree 失敗（已實測），改用 `liblzf`；`Redis::COMPRESSION_LZF/LZ4/ZSTD` 必須都存在 |
| memcached | system libmemcached、json/sasl/session on、fastlz 自帶、protocol off | 相同 | 驗證 `php --ri memcached` 的 Session/JSON/SASL 全為 yes |
| zstd | 0.18.0 **自帶** zstd 函式庫 | **改用系統 libzstd 1.4.8** | 避免 static link 同符號競合；`zstd_compress()` 行為不變 |
| gmp / pgsql / pdo_pgsql | bundled | 相同 | 8.0 比 7.4 多這 3 個 |
| opcache | shared（IPE 編譯） | shared（同一份 patched source） | 必須 |
| sodium | shared | shared | 不變 |

### 5.4 build 依賴（builder）

```
$PHPIZE_DEPS ca-certificates curl xz-utils patch
libargon2-dev libcurl4-openssl-dev libonig-dev libreadline-dev libsodium-dev
libsqlite3-dev libssl-dev libxml2-dev zlib1g-dev
libbz2-dev libffi-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev
libwebp-dev libxpm-dev libzip-dev libsnmp-dev libmcrypt-dev
libmagickwand-dev libmemcached-dev libsasl2-dev
liblz4-dev libzstd-dev liblzf-dev libgmp-dev libpq-dev
```

### 5.5 runtime 依賴（final stage）

```
ca-certificates curl xz-utils tzdata unzip

libargon2-1 libreadline8 libxml2 libssl1.1 libsqlite3-0 zlib1g libcurl4
libonig5 libsodium23

libbz2-1.0 libffi7 libfreetype6 libjpeg62-turbo libpng16-16 libwebp6
libwebpmux3 libwebpdemux2 libxpm4 libx11-6 libxext6 libxau6 libxdmcp6

libzip4 libsnmp40 libsnmp-base libmcrypt4 libmemcached11 libmemcachedutil2
libsasl2-2 liblz4-1 libzstd1 liblzf1 libstdc++6 libgomp1

libgmp10 libpq5

libmagickwand-6.q16-6 libmagickcore-6.q16-6 libmagickcore-6.q16-6-extra
imagemagick-6-common ghostscript fonts-urw-base35 fontconfig
```

> 已用現行 image 的 `ldd php / php-fpm / *.so` 反推，並確認 `php` 直接依賴
> `libargon2 libcurl4 libonig5 libssl1.1 libsqlite3 libxml2 libsodium23 libreadline8`。
> §10.2 會再加一道「`ldd` 不得有 not found」的驗證。

---

## 6. 設計細節

### 6.1 Dockerfile 三階段

```
# syntax=docker/dockerfile:1
FROM debian:bullseye-slim AS base
    - bullseye archive 鏡像 + Acquire::Check-Valid-Until false
    - no-debian-php pin
    - ENV PHP_INI_DIR + /var/www/html

FROM base AS builder
    - ENV PHPIZE_DEPS / PHP_CFLAGS / PHP_CPPFLAGS / PHP_LDFLAGS
    - ENV PHP_VERSION=8.0.30 / PHP_URL / PHP_SHA256 / PHP_CVE_PATCH_SHA256（不變）
    - COPY docker-php-scripts/ /usr/local/bin/     # source, ext-enable, clean, static-install/remove
    - COPY scripts/static-extensions.conf /usr/local/share/php-docker/
    - COPY scripts/build-php-static.sh /usr/local/bin/
    - COPY patches/php-8.0-CVE-2026-109618-109619.patch /usr/src/php-cve.patch
    - ADD composer.phar 2.11.2（版本 + checksum 固定）
    - RUN apt-get update && apt-get install <build deps> && build-php-static.sh
    - RUN FPM 基礎設定（沿用官方 docker-library 8.0 區塊，內容不變）

FROM base AS runtime
    - ENV TZ / WWW_UID / WWW_GID / PHP_CVE_PATCHES
    - RUN apt-get install <runtime deps>
    - COPY --from=builder /usr/local/bin/php
    - COPY --from=builder /usr/local/bin/composer
    - COPY --from=builder /usr/local/sbin/php-fpm
    - COPY --from=builder /usr/local/lib/php
    - COPY --from=builder /usr/local/etc
    - RUN FPM tuning（現行 sed 區塊，內容不變）
    - STOPSIGNAL / EXPOSE
    - RUN CA bundle（固定日期 2026-11-05 + SHA256，沿用現行）
    - COPY file-upload.conf / opcache.ini / ca-bundle.ini / cve marker / entrypoint
    - USER www-data
```

**移除的段落**：最前面安裝 `$PHPIZE_DEPS` 的 RUN、獨立下載 `php.tar.xz` 的 RUN、
`RUN docker-php-ext-enable sodium`、`ADD install-php-extensions`、
`COPY scripts/install-extensions.sh` + `RUN install-extensions.sh`。

**保持不變**：CVE 補丁與 SHA256、CA bundle pin、FPM 設定、`entrypoint.sh`、
`pm.max_requests=5`、`TZ=Asia/Hong_Kong`、`USER www-data`、CVE marker。

### 6.2 `scripts/build-php-static.sh`

流程（單一 RUN，builder 內）：

1. 下載 `php-8.0.30.tar.xz`，驗 `PHP_SHA256`；驗 `php-cve.patch` 的 SHA256。
2. `docker-php-source extract` → `patch -p1 --fuzz=0` → `touch .docker-cve-patched`。
3. 下載 6 個 PECL tarball（固定版本 + SHA256），解到 `/usr/src/php/ext/<name>`。
4. 寫入 `/usr/src/php/.docker-configure-base`（PHP 8.0 官方旗標，**含 `--enable-opcache`**）
   與 `/usr/src/php/.docker-static-exts`（22 個 ext 名稱）。
5. `./buildconf --force`（此時 `config-stubs` 會納入 PECL 目錄）。
6. 由 `static-extensions.conf` 產生 ext flags，`./configure <base> <ext flags>`。
7. `make -j$(nproc)` → `make install` → 刪掉安裝樹的 `*.a` → strip `/usr/local`。
8. `cp php.ini-* "$PHP_INI_DIR/"`。
9. `docker-php-ext-enable opcache sodium`（只產生這兩個 ini）。

與 7.4 版的差異：

| 項目 | 7.4 | 8.0 |
|---|---|---|
| `PHP_VERSION` | 7.4.33 | 8.0.30 |
| base configure | 含 `--with-sodium=shared`、`--enable-opcache` | 相同（見下方完整清單） |
| PECL 清單 | 5 個（無 zstd） | 6 個（+ zstd 0.18.0） |
| 靜態 ext | 18 | 22（+ gmp, pdo_pgsql, pgsql, zstd） |
| OPcache 註解 | 「PHP 7.4 強制 shared」 | 「PHP 8.0 強制 shared」 |

`.docker-configure-base` 應寫入的 PHP 本體旗標（與現行 Dockerfile 完全一致）：

```
--build=$gnuArch
--with-config-file-path=$PHP_INI_DIR
--with-config-file-scan-dir=$PHP_INI_DIR/conf.d
--enable-option-checking=fatal
--with-mhash
--with-pic
--enable-ftp
--enable-mbstring
--enable-mysqlnd
--with-password-argon2
--with-sodium=shared
--with-pdo-sqlite=/usr
--with-sqlite3=/usr
--with-curl
--with-iconv
--with-openssl
--with-readline
--with-zlib
--disable-phpdbg
--with-pear
--with-libdir=lib/$debMultiarch
--disable-cgi
--enable-fpm
--with-fpm-user=www-data
--with-fpm-group=www-data
--enable-opcache
```

> `s390x-linux-gnu` 仍保留 `--without-pcre-jit` 條件（現行 Dockerfile 已有）。
> `--enable-opcache` 雖然在 8.0 預設開啟，仍明寫以固定行為。

### 6.3 `docker-php-scripts/`

新增（與 7.4 分支同款，內容僅需把「7.4」字樣改 8.0）：

| 檔案 | 用途 |
|---|---|
| `docker-php-clean` | `source` / `deps` / `all`；builder 或除錯用；文件註明 layer immutable |
| `docker-php-ext-static-install` | 由 manifest 重跑 buildconf/configure/make/install；支援 `-jN`、`--configure-args`、`--clean` |
| `docker-php-ext-static-remove` | 從 manifest 移除後重跑 |

移除：`docker-php-ext-install`、`docker-php-ext-configure`
（runtime 沒有 toolchain，留著只會被誤用；builder 內如需重編請用 static-install）。
保留：`docker-php-source`、`docker-php-ext-enable`。

### 6.4 Composer

不再用 IPE 的 `@composer`，改為固定 phar（與 7.4 分支一致）：

```dockerfile
ADD --chmod=0755 --checksum=sha256:dd158c0afd41d15fac89e1b4e47b5d42911fe316c3687cd5edac98319b25d028 \
    https://getcomposer.org/download/2.11.2/composer.phar \
    /usr/local/bin/composer
```

> 2.11.2 仍支援 PHP 7.2.5+，可在 8.0.30 執行。版本與 checksum 與 7.4 分支相同，
> 便於兩個分支共用驗證結果。

### 6.5 `.gitattributes` / `.dockerignore`

本專案在 Windows 上開發，以下檔案若被 checkout 成 CRLF 會直接壞掉：

```gitattributes
*.sh text eol=lf
entrypoint.sh text eol=lf
*.patch text eol=lf
*.ini text eol=lf
*.conf text eol=lf          # static-extensions.conf 用 TAB 分隔，CRLF 會把 \r 帶進 flag
docker-php-scripts/* text eol=lf   # 無副檔名的 shell 腳本
scripts/* text eol=lf
```

`.dockerignore` 可順手補 `docker-compose.yml`、`.dockerignore`（與 7.4 分支一致），
避免 context 汙染（非必要）。

---

## 7. 預期效果

| 項目 | 現行 | 目標 | 實測（2026-11-12, amd64） |
|---|---|---|---|
| extension `.so` | 24 | **2**（`opcache.so`、`sodium.so`） | ✅ 2 |
| 擴充 ini | 24 | **2** | ✅ 2（`docker-php-ext-opcache.ini`、`docker-php-ext-sodium.ini`） |
| `php -m` | 59 | 59（不變） | ✅ 完全相同 |
| `/usr/src/php.tar.xz` | 11MB | 不存在（builder 內才會有） | ✅ 不存在 |
| `install-php-extensions` | 262KB | 不存在 | ✅ 不存在 |
| `$PHPIZE_DEPS` layer | 284MB（獨立 layer） | 不存在（builder 才有） | ✅ 不存在 |
| 擴充安裝 layer | 129MB | 不存在 | ✅ 不存在 |
| php binary | 17MB | 約 +4~6MB（22 個 ext 併入） | ✅ 21MB |
| **amd64 disk usage** | **800MB** | **約 460~490MB**（目標 ≤ 500MB） | ✅ **467MB**（content 109MB） |

> 量測方式一律用 `docker image ls --tree` / `docker image inspect --format '{{.Size}}'`
> 與 `docker history`，不要用 `du` 推估 layer。

---

## 8. 風險與對策

| 風險 | 影響 | 對策 |
|---|---|---|
| zstd 0.18.0 in-tree 靜態失敗（自帶原始碼 / `.S` / 路徑） | build fail | 本方案已改用 `--with-libzstd`（系統 1.4.8），跳過 bundled 路徑；若仍失敗，退回「zstd 維持 `.so`」（方案 B 的單點例外） |
| redis LZF 在 in-tree 找不到 `liblzf` 標頭 | build fail | **已實測觸發**（`fatal error: lzf.h`）；改用 `--with-liblzf` + `liblzf-dev` / `liblzf1`（bullseye 3.6-3，`liblzf.pc` 提供 `-llzf`） |
| memcached static 行為與 IPE 不同（session/json/sasl/fastlz） | 功能缺損 | 以 §5.3 的 flags 對齊；驗證 `php --ri memcached` 五項旗標 |
| OPcache 被誤設為靜態 | configure 忽略或 build 失敗 | 保留 `opcache.so` + `zend_extension` ini；build 後檢查 extension dir 恰為 2 個 `.so` |
| timezonedb 靜態註冊順序（依賴 `date`） | startup 警告 / 時區資料未生效 | 驗證 `php -m`、`php -r 'echo timezone_version_get();'`（應為 2026.5） |
| runtime 少裝 lib 導致 php-fpm 起不來 | 啟動失敗 | §5.5 清單 + `ldd` 無 `not found` + `php-fpm -t` + 實際啟動 |
| 失去 in-container 編譯能力（無 IPE / 無 gcc） | 使用者不能在容器內 `pecl install` | 明確列為取捨；需要時用 `docker build --target builder` 或 `docker-php-ext-static-install`（builder 內） |
| `docker-php-ext-install` 被移除造成下游 build 失敗 | 下游 Dockerfile 需調整 | 文件明載 breaking change；如要保留，可只在 builder 保留（不進 runtime） |
| arm64 與 amd64 行為差異 | CI 失敗 | 沿用現有原生 runner（`ubuntu-24.04-arm`），不用 QEMU；PHP 8.0 的 OPcache JIT 在 arm64 本來就關閉，與現狀一致 |
| `static-extensions.conf` 被 CRLF 汙染 | configure 收到帶 `\r` 的 flag | `.gitattributes` 強制 LF（§6.5） |
| 體積未如預期 | 目標落空 | 用 `docker history` 確認 runtime 沒有 build deps / source；必要時檢查 builder COPY 範圍 |

---

## 9. 任務清單

| # | Task | 狀態 |
|---|---|---|
| 1 | 確認採方案 A（multi-stage + 全靜態）、sodium 維持 shared | ✅ Done（§12） |
| 2 | 新增 `scripts/static-extensions.conf`（§5.2） | ✅ Done |
| 3 | 新增 `scripts/build-php-static.sh`（§6.2） | ✅ Done |
| 4 | 新增 `docker-php-scripts/docker-php-clean` | ✅ Done |
| 5 | 新增 `docker-php-scripts/docker-php-ext-static-install` / `-remove` | ✅ Done |
| 6 | 移除 `docker-php-scripts/docker-php-ext-install` / `-configure` | ✅ Done |
| 7 | 改寫 Dockerfile 為 base / builder / runtime 三階段（§6.1） | ✅ Done |
| 8 | 移除 `scripts/install-extensions.sh` 與 IPE `ADD` | ✅ Done |
| 9 | 固定 Composer 2.11.2（§6.4） | ✅ Done |
| 10 | 更新 `.gitattributes`（§6.5） | ✅ Done |
| 11 | 本地 amd64 build + `php -m` 59 模組對照 | ✅ Done（模組清單完全相同） |
| 12 | 逐項功能 smoke test（§10.3） | ✅ Done |
| 13 | 量測 image size / layer before-after（§10.4） | ✅ Done（800MB → 467MB） |
| 14 | CA bundle 驗證（`tests/verify-ca-bundle.php`） | ✅ Done（8 passed / 0 errors） |
| 15 | builder target 驗證 `docker-php-ext-static-install calendar` | ✅ Done |
| 16 | arm64 CI build 驗證（`v*` tag） | ⬜ Pending |
| 17 | 更新 `README.md`、`AGENTS.md`、本文件狀態 | ✅ Done |

建議合併為 2~3 個 commit：

1. `feat(docker): 擴充改為靜態內嵌並以多階段建置縮小映像`（任務 2~10）
2. `docs: 更新靜態內嵌說明與 AGENTS/README`（任務 17）
3. 驗證結果回填（任務 11~16 的數據）

---

## 10. 驗證計畫

### 10.1 Build

```bash
docker build -t mmhk/php-docker:8.0-fpm-static .
docker build --target builder -t mmhk/php-docker:8.0-fpm-builder .
```

通過條件：build 成功、`make` 期間無 `--enable-option-checking=fatal` 錯誤、
`php --version` 顯示 `PHP 8.0.30`。

### 10.2 模組 / 連結 parity

```bash
docker run --rm mmhk/php-docker:8.0-fpm-static php -v
docker run --rm mmhk/php-docker:8.0-fpm-static php -m
docker run --rm mmhk/php-docker:8.0-fpm-static php -r 'echo ini_get("extension_dir"), PHP_EOL;'
docker run --rm mmhk/php-docker:8.0-fpm-static sh -c \
  'ls -1 "$(php -r "echo ini_get(\"extension_dir\");")"'
docker run --rm mmhk/php-docker:8.0-fpm-static sh -c \
  'ldd /usr/local/bin/php /usr/local/sbin/php-fpm | grep "not found" || echo "no missing libs"'
```

通過條件：

- `php -m` 與現行 image 的 **59 個模組逐項一致**（含 `Zend OPcache`、`sodium`）；
- extension dir **只有** `opcache.so`、`sodium.so`；
- `ldd` 無 `not found`；
- 不存在 `/usr/src/php.tar.xz`、`/usr/local/bin/install-php-extensions`、
  `/usr/src/php`、`gcc`、`make`。

### 10.3 功能 smoke test

```bash
docker run --rm --user root mmhk/php-docker:8.0-fpm-static sh -c '
  php -r "var_export(gd_info());" &&
  php -r "echo (new Imagick())->getVersion(), PHP_EOL;" &&
  php -r "var_dump(class_exists(\"Memcached\"));" &&
  php -r "var_dump(defined(\"Redis::COMPRESSION_LZF\"), defined(\"Redis::COMPRESSION_LZ4\"), defined(\"Redis::COMPRESSION_ZSTD\"));" &&
  php -r "echo timezone_version_get(), PHP_EOL;" &&
  php -r "echo mcrypt_get_cipher_name(MCRYPT_RIJNDAEL_128), PHP_EOL;" &&
  php -r "echo ZipArchive::LIBZIP_VERSION, PHP_EOL;" &&
  php -r "echo gmp_strval(gmp_add(1,2)), PHP_EOL;" &&
  php -r "echo pg_escape_string(\"a\"), PHP_EOL;" &&
  php -r "var_dump(class_exists(\"FFI\"), function_exists(\"zstd_compress\"));" &&
  php --ri memcached | grep -E "SASL support|Session support|json support" &&
  php-fpm -t
'
```

預期：gd 全 true、Imagick 3.8.1 / IM 6.9.11、memcached Session/JSON/SASL 全 yes、
Redis 三個壓縮常數皆存在、timezone `2026.5`、libzip `1.7.3`、gmp/pgsql/FFI/zstd 正常。

### 10.4 體積量測

```bash
docker image ls --tree mmhk/php-docker:8.0-fpm        # 現行 amd64 800MB
docker image ls --tree mmhk/php-docker:8.0-fpm-static
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' \
  mmhk/php-docker:8.0-fpm-static | head -20
```

目標：amd64 disk usage ≤ 500MB；`docker history` 不出現 `$PHPIZE_DEPS`、
`build-php-static.sh`、`install-extensions.sh` 等建置 layer。

### 10.5 CA bundle

```bash
docker run --rm -v "$PWD/tests/verify-ca-bundle.php:/verify.php:ro" \
  mmhk/php-docker:8.0-fpm-static php /verify.php
```

預期與現行一致（8 passed / 0 errors）。

### 10.6 arm64

推送 `v*` tag 後由 `.github/workflows/release.yml` 以原生 `ubuntu-24.04-arm`
建置；merge job 應產生同時含 amd64/arm64 的 manifest。**不使用 QEMU**。

### 10.7 builder 的 static-install（可選）

```bash
docker run --rm --user root mmhk/php-docker:8.0-fpm-builder sh -c '
  docker-php-ext-static-install calendar &&
  php -r "echo cal_days_in_month(CAL_GREGORIAN, 2, 2024), PHP_EOL;"
'
```

用來證明 `docker-php-ext-static-install` 在 builder 內仍可用（7.4 分支已用
`calendar` 驗證過）。

### 10.8 本機 amd64 實測結果（2026-11-12）

| 項目 | 結果 |
|---|---|
| `php -v` | PHP 8.0.30 (cli) (NTS) + Zend OPcache v8.0.30 |
| `php -m` | 與現行 image **完全相同**（59 個模組） |
| extension dir | 只有 `opcache.so`、`sodium.so` |
| conf.d | 只有 6 個檔（ca-bundle / docker-fpm / opcache ext ini / sodium ini / opcache.ini / zz-cve） |
| `/usr/src/php`、`php.tar.xz`、IPE、gcc、make、phpize | 全部不存在 |
| `ldd php / php-fpm` | 無 `not found` |
| `php-fpm -t` | 通過 |
| 實際啟動容器 | `fpm is running` / `ready to handle connections`，`/proc/1/exe -> php-fpm` |
| gd | FreeType/JPEG/PNG/WebP/XPM 全 true |
| Imagick | 3.8.1 / ImageMagick 6.9.11-60 |
| Memcached | 3.4.0，libmemcached 1.0.18，SASL/Session/JSON 全 yes |
| Redis | `COMPRESSION_LZF` / `LZ4` / `ZSTD` 全存在 |
| timezonedb | 2026.5 |
| mcrypt | Rijndael-128（PHP 8.0 會提示 deprecated，與舊 image 相同） |
| zip / gmp / pgsql / FFI / zstd roundtrip / sodium / opcache | 全部通過 |
| CA bundle | 8 passed / 0 errors |
| JIT | `opcache.jit=tracing`、`buffer 128M` 生效 |
| CVE 標識 | marker 檔、`zz-cve*.ini`、`PHP_CVE_PATCHES`（env/$_ENV）皆存在 |
| Composer | 2.11.2 |
| **image 大小** | **800MB → 467MB（amd64 disk usage）** |
| `docker-php-ext-static-install calendar` | builder 內成功，`cal_days_in_month` 可用 |

> builder stage 仍保留 `/usr/src/php` 與 toolchain（供 static-install），
> 但不會進入 runtime image。

---

## 11. 回滾

- 方案整體失敗：`git revert` 對應 commit，即可回到現行 IPE / `.so` 流程
  （本次會移除 `scripts/install-extensions.sh` 與 IPE，需一併還原）。
- 只有個別 PECL 靜態失敗（例如 zstd）：退回方案 B 的單點例外，
  該擴充維持 `.so`，其餘仍靜態；不需要整支回滾。
- runtime 套件清單漏裝導致啟動失敗：先在 runtime 補齊套件，確認功能後再精簡，
  不要反過來先精簡再除錯。

---

## 12. 決策（已確認）

1. **採方案 A（multi-stage + 22 擴充全靜態）** — ✅ 已確認並實作。
2. **zstd 使用系統 `libzstd`** — ✅ 已確認（`--with-libzstd`），避免與 redis 的
   libzstd 同符號競合；代價是 zstd 函式庫從 1.5.x 變 bullseye 的 1.4.8（API 相容）。
3. **`sodium` 第一階段維持 shared** — ✅ 已確認。
4. **移除 `docker-php-ext-install` / `docker-php-ext-configure`** — ✅ 已確認
   （runtime 無 toolchain；builder 內用 `docker-php-ext-static-install`）。
5. **Composer 改為固定 phar 2.11.2 + checksum** — ✅ 已確認。
6. **runtime 不補 `sudo`** — ✅ 已確認，維持現行 8.0 image 套件行為。
