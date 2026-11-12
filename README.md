# PHP-Docker 

适用于容器化的PHP执行环境

### 專案結構

```
.
├── Dockerfile                  # base / builder / runtime 三階段
├── scripts/                    # builder 用：PHP 與擴充建置（見 scripts/README.md）
│   ├── build-php-static.sh
│   └── static-extensions.conf
├── docker-php-scripts/         # builder 用的 docker-php-* 輔助命令
├── patches/                    # CVE backport 補丁
├── docs/                       # 設計 / 驗證文件（見 docs/README.md）
│   ├── plans/                  # 現行方案
│   └── archive/                # 已廢止方案
├── tests/                      # CA bundle 驗證腳本（不進映像）
└── .github/workflows/          # multi-arch 發佈流程
```

| 想了解 | 看哪裡 |
|-|-|
| 怎麼用這個映像 | 本文件下方章節 |
| 擴充怎麼編進 PHP | `docs/plans/php-8.0-static-extensions.md` |
| 建置腳本與新增/升級擴充 | `scripts/README.md` |
| 文件索引 | `docs/README.md` |
| 維護者注意事項 / gotchas | `AGENTS.md` |

### Environment

|ENV|remark|default value|
|-|-|-|
|WWW_UID|www-data(容器自带fpm执行账户)账户的UID|1000|
|WWW_GID|www-data(容器自带fpm执行账户)账户的GID|1000|

### 來源與安全修補

本鏡像**從原始碼編譯** PHP 8.0.30（基底 `debian:bullseye-slim`），並套用官方
backport 補丁修補 **CVE-2026-109618 / CVE-2026-109619**（PHP2Shell）：

- 補丁：`patches/php-8.0-CVE-2026-109618-109619.patch`（來源 php-src 分支
  `PHP-8.0-CVE-2026-109618-109619`，commit `82f8f31b`），可直接在 repo 內審閱。
- 原始碼 tarball 與補丁均以 SHA256 固定，建置時驗證。
- 映像內含證明檔 `/usr/local/etc/php/cve-2026-109618-109619.patched`。
- `phpinfo()` 另可見兩個標識：`Additional .ini files parsed` 內的
  `zz-cve-2026-109618-109619.ini`，以及環境變數 `PHP_CVE_PATCHES`。
- 所有建置輸入都固定：PHP tarball、CVE 補丁、PECL 擴充 tarball
  （`scripts/build-php-static.sh`）與 Composer 版本（2.11.2 phar + checksum）。

> PHP 8.0 已於 2023-11 EOL，官方不再提供 8.0 修復版，因此以源碼 backport 方式修補。

### 擴充編譯方式（靜態內嵌）

除 OPcache（PHP 8.0 強制 shared）與 sodium（與官方一致維持 shared）外，
所有擴充都在建置時**直接編進 `php` / `php-fpm` binary**，執行期不再有對應的
`.so` 與 `extension=` ini。映像因此採三階段建置：

| Stage | 內容 |
|-|-|
| `base` | bullseye archive 來源設定、`no-debian-php` pin |
| `builder` | PHP 原始碼 + CVE 補丁 + 編譯器 + 22 個靜態擴充（不進最終映像） |
| `runtime` | 只複製 `/usr/local` 的執行期檔案與必要的 runtime library |

需要另外編譯擴充時，請使用 builder stage：

```bash
docker build --target builder -t mmhk/php-docker:8.0-fpm-builder .
docker run --rm -it --user root mmhk/php-docker:8.0-fpm-builder sh
# 容器內：
docker-php-ext-static-install calendar   # 需要先安裝該擴充的系統依賴
```

### 已安装扩展

||||
|-|-|-|
|composer|gd|memcached|
|gettext|imagick|mcrypt|
|mysqli|redis|pdo_mysql|
|pdo_pgsql|pgsql|gmp|
|zstd|opcache|exif|
|bcmath|soap|sockets|
|timezonedb|zip|snmp|
|bz2|shmop|ffi|

> 除 OPcache 與 sodium 仍為 `.so` 外，其餘擴充都靜態編進 binary。
> PECL 擴充（memcached / imagick / mcrypt / redis / zstd / timezonedb）以**固定版本 tarball**
> 在 `scripts/build-php-static.sh` 內下載、驗證 SHA256 後解到 `ext/` 一起編譯。這是為了繞過
> pecl.php.net 的 REST metadata 回傳 gzip 導致 `pecl install <name>` 失敗的問題。

### OPcache / JIT

通过独立的 `opcache.ini` 配置，已启用 JIT tracing 模式：

| 设置 | 值 |
|-|-|
|opcache.enable|1|
|opcache.jit|tracing|
|opcache.jit_buffer_size|128M|

如需调整，修改 `opcache.ini` 后重新构建镜像即可。

> **注意**：PHP 8.0 的 JIT 默认为 `opcache.jit=tracing` 和 `opcache.jit_buffer_size=0`（禁用）。设置 `jit_buffer_size` 后 JIT 才会生效。

### RUN

```
docker run -d --name php-fpm -p 9000:9000 -v /var/www/html:/var/www/html mmhk/php-docker:8.0-fpm
```

### 自訂配置（docker-compose）

如果需要覆蓋預設配置，可以透過 volume 掛載自訂文件：

```yaml
version: '3.8'
services:
  php-docker:
    image: mmhk/php-docker:8.0-fpm
    volumes:
      - ./www:/var/www/html
      # 覆蓋 opcache 配置
      - ./config/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      # 覆蓋 upload 限制
      - ./config/file-upload.conf:/usr/local/etc/php-fpm.d/file-upload.conf:ro
      # 新增自訂 FPM pool 配置
      - ./config/custom-pool.conf:/usr/local/etc/php-fpm.d/custom-pool.conf:ro
    ports:
      - "9000:9000"
```

**opcache.ini 範例**（調整 JIT buffer）：

```ini
[opcache]
opcache.enable=1
opcache.jit=tracing
opcache.jit_buffer_size=256M
opcache.memory_consumption=256
```

**file-upload.conf 範例**（調整上傳限制）：

```ini
[www]
php_admin_value[post_max_size]=100M
php_admin_value[upload_max_filesize]=95M
```

**custom-pool.conf 範例**（新增 FPM pool）：

```ini
[custom]
user = www-data
group = www-data
listen = 9001
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
```

修改配置後重新啟動容器即可生效：

```bash
docker compose down
docker compose up -d
```

### 配置優先級說明

PHP 在 `/usr/local/etc/php/conf.d/` 目錄中按**檔名字母順序**載入所有 `.ini` 檔案，後面載入的會覆蓋前面的相同指令。

容器內相關檔案：

| 檔案 | 用途 |
|-|-|
|`docker-php-ext-opcache.ini`|載入 opcache 擴展（`zend_extension=opcache`）|
|`opcache.ini`|opcache 運行時配置（JIT、buffer 等）|

如果用 Docker volume 掛載自訂配置，建議使用排序靠後的檔名以確保優先級：

```yaml
volumes:
  # 使用 99- 前綴確保最後載入
  - ./config/opcache.ini:/usr/local/etc/php/conf.d/99-opcache.ini:ro
```

這樣可以避免被其他 `.ini` 檔案覆蓋。
