# 建置腳本導覽（`scripts/` 與 `docker-php-scripts/`）

> 只在 **builder stage** 使用；final (runtime) image 不含這些腳本、編譯器或 PHP 原始碼。

## 檔案

| 路徑 | 用途 |
|---|---|
| `scripts/build-php-static.sh` | builder 的唯一建置入口：下載 PHP → 驗 SHA256 → 套 CVE patch → 暫存 PECL → `buildconf` → `configure` → `make` → `install` → strip |
| `scripts/static-extensions.conf` | 擴充 → configure flags 對照表（TAB 分隔），由 build script 與 `docker-php-ext-static-install` 共用 |
| `docker-php-scripts/docker-php-source` | vendored（docker-library/php）：`extract` / `delete` `/usr/src/php` |
| `docker-php-scripts/docker-php-ext-enable` | vendored：為 `.so` 產生 ini（本專案只用於 `opcache` / `sodium`） |
| `docker-php-scripts/docker-php-clean` | `source` / `deps` / `all`：清除建置輸入與 build deps |
| `docker-php-scripts/docker-php-ext-static-install` | 在 builder 內追加靜態擴充（會重跑 configure/make） |
| `docker-php-scripts/docker-php-ext-static-remove` | 從 manifest 移除擴充後重跑同一流程 |

## 建置流程

```
Dockerfile(builder)
  └─ RUN build-php-static.sh
       ├─ 讀 PHP_VERSION / PHP_URL / PHP_SHA256 / PHP_CVE_PATCH_SHA256（Dockerfile ENV）
       ├─ 下載 PECL tarball（版本與 SHA256 寫在本腳本的 heredoc 內）
       ├─ 解到 /usr/src/php/ext/<name>
       ├─ 產生 /usr/src/php/.docker-configure-base
       ├─ 產生 /usr/src/php/.docker-static-exts（靜態擴充 manifest）
       ├─ 逐項讀 static-extensions.conf 產生 configure flags
       └─ buildconf / configure / make / make install
```

可覆寫的環境變數：

| 變數 | 預設 | 說明 |
|---|---|---|
| `PHP_STATIC_EXTS` | 22 個擴充（見腳本） | 靜態內嵌清單；必須與 `static-extensions.conf` 一致 |
| `STATIC_CONF` | `/usr/local/share/php-docker/static-extensions.conf` | 對照表位置 |
| `PECL_SRC` | `/usr/src/pecl` | PECL tarball 暫存目錄（建置後刪除） |
| `PHP_INI_DIR` | `/usr/local/etc/php` | ini 目錄 |

## 新增擴充

### A. bundled（PHP 原始碼內已有 `ext/<name>/config.m4`）

1. 在 `scripts/static-extensions.conf` 加一行：`<name><TAB><configure flags>`。
2. 在 `scripts/build-php-static.sh` 的 `PHP_STATIC_EXTS` 預設值加入 `<name>`。
3. 在 `Dockerfile` builder 的 apt 清單加入 build 依賴。
4. 在 `Dockerfile` runtime 的 apt 清單加入 runtime library。
5. 重建：`docker build -t mmhk/php-docker:8.0-fpm-static .`
6. 驗證：`php -m`、對應的 `php --ri <name>` / 功能測試。
7. 同步 `README.md` 的「已安装扩展」表。

### B. PECL（原始碼內沒有）

1. 在 `scripts/build-php-static.sh` 的 `PECL_PACKAGES` heredoc 加
   `name version sha256`（sha256 取自 `https://pecl.php.net/get/<name>-<version>.tgz`）。
2. 其餘同 A 的第 1、2、3、4 步。
3. 若該擴充的 `config.m4` 需要額外 flag（例如 redis 的 `--with-liblzf`），
   直接寫在 `static-extensions.conf`。

> 不要在 runtime image 內 `pecl install` / `docker-php-ext-install`：
> final image 沒有編譯器，且 PECL REST metadata 有 gzip 問題（見 `AGENTS.md`）。

## 升級 PECL 版本

只改 `scripts/build-php-static.sh` 的 `name version sha256` 三欄：

```sh
curl -fsSL -o /tmp/pkg.tgz https://pecl.php.net/get/<name>-<version>.tgz
sha256sum /tmp/pkg.tgz
```

升版後確認該版本 `package.xml` 仍接受 PHP 8.0，並重跑 §驗證（`php -m` + smoke test）。

## 診斷 / 除錯

```bash
# 建 builder（保留 source + toolchain）
docker build --target builder -t mmhk/php-docker:8.0-fpm-builder .

# 在 builder 內追加擴充（範例：calendar）
docker run --rm --user root mmhk/php-docker:8.0-fpm-builder \
  sh -c 'docker-php-ext-static-install -j4 calendar && php -r "echo cal_days_in_month(CAL_GREGORIAN,2,2024);"'

# 清除建置輸入（只在 builder / 容器內有意義；image layer 不會因此變小）
docker-php-clean source
docker-php-clean deps
docker-php-clean all
```

`docker-php-ext-static-install` 需要：

- `/usr/src/php`（已解壓、已套 CVE patch）
- `/usr/src/php/.docker-configure-base`
- `/usr/src/php/.docker-static-exts`
- 該擴充的系統依賴（腳本不解析 apt）

## 注意事項

- **LF 換行**：`docker-php-scripts/*`（無副檔名）、`scripts/*`、`*.conf` 必須是 LF，
  `.gitattributes` 已強制；`static-extensions.conf` 若帶 `\r` 會讓 configure flag 壞掉。
- **TAB 分隔**：`static-extensions.conf` 的欄位用 TAB，不是空白。
- `build-php-static.sh` 必須與下載 / 安裝在同一個 Docker `RUN`（layer 不可變）。
- `docker-php-ext-static-install` 只能在 builder stage 使用；final image 沒有 source/toolchain。
