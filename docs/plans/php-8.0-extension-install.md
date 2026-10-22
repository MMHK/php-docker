# PHP 8.0 擴充安裝方案（PECL 固定 tarball）

> 分支：`8.0-fpm`　｜　目標鏡像：`mmhk/php-docker:8.0-fpm`
> 狀態：本機重裝驗證通過（第 6 節），CI 待驗
> 相關：`docs/plans/php-8.0-cve-2026-109618-109619-patch.md`（CVE 補丁方案）

---

## 1. 問題

2026-10 CI 建置在擴充安裝層失敗：

```
Package "memcached" Version "3.4.0" does not have REST xml available
install failed
install-php-extensions failed after 5 attempts
```

同一錯誤先前也在 `redis` 出現，當時只對 redis 做了單點繞道（見 CVE 方案 7.5）。
這次換成 `memcached`，且重試 5 次全數失敗 —— 證明那是**通道層級**的問題，不是個別套件。

## 2. 根因

- `pecl.php.net`（BunnyCDN）對 PEAR 的 REST metadata 回應帶 `content-encoding: gzip`，
  而 PEAR 的 HTTP client **不會解壓縮**，於是 XML 解析失敗：

  ```
  Debug: Invalid xml downloaded from "https://pecl.php.net/rest/p/<pkg>/info.xml":
         XML Error: 'Not well-formed (invalid token)' on line '1'
  ```

- 這是**內容可讀性問題，不是連線問題**：相同 URL 用 `curl --compressed` 取得的是合法 XML，
  所以重試幾次結果都一樣，`install-php-extensions` 的 5 次重試只是浪費時間。
- 只有「需要向 channel 查版本／下載路徑」的擴充會受影響；bundled 擴充由
  `docker-php-ext-install` 直接從 `/usr/src/php.tar.xz` 編譯，完全不碰 REST。

## 3. 影響範圍：整個 PECL channel，不是只有那幾個擴充

**判準**：PHP 8.0.30 原始碼樹內有 `/usr/src/php/ext/<name>/config.m4` → bundled；
沒有 → 只能走 PECL，就會踩到。

**實測**（用一個我們根本沒用的擴充）：

```
$ pecl remote-info apcu
Unknown package: "apcu" in channel "pecl.php.net"
Debug: Invalid xml downloaded from "https://pecl.php.net/rest/p/apcu/info.xml" ...
```

連「查詢」都失敗，可見與套件、版本無關。

本專案目前的清單（共 24 項）：

| 類別 | 數量 | 擴充 | 受影響 |
|---|---|---|---|
| PECL | 6 | `memcached` `imagick` `mcrypt` `redis` `zstd` `timezonedb` | ✅ 必須固定 tarball |
| bundled | 17 | `gd` `gmp` `gettext` `mysqli` `pdo_mysql` `pdo_pgsql` `pgsql` `opcache` `exif` `bcmath` `soap` `sockets` `zip` `snmp` `bz2` `shmop` `ffi` | ❌ |
| 特殊 | 1 | `@composer`（getcomposer.org 下載） | ❌ |

> 判準可隨時重查：
> `tar -tf /usr/src/php.tar.xz | sed -n 's|^php-8.0.30/ext/\([^/]*\)/config.m4$|\1|p'`

## 4. 方案比較

| 方案 | 說明 | 結論 |
|---|---|---|
| A. 加重試 / backoff | 失敗是永久性的（伺服器回 200，內容壞掉） | ❌ 無效 |
| B. 直接把 tarball URL 交給 `install-php-extensions` | IPE 支援 URL，但 PECL tarball 頂層同時有 `package.xml` 與 `<name>-<version>/`，`getPackageSource` 會退回暫存目錄，PEAR 驗證相對路徑檔案（如 redis 的 `liblzf/LICENSE`）時失敗；且無 SHA256 可驗 | ❌ |
| C. **自行下載固定 tarball，解壓成目錄後交給 IPE** | 完全繞過 channel；可固定版本與 SHA256；沿用已在 redis 驗證過的機制 | ✅ **採用** |
| D. 自架 PECL mirror / 換 channel | 需要額外服務與憑證 | ❌ 成本過高 |

## 5. 最終方案

### 5.1 `scripts/install-extensions.sh`

Dockerfile 只保留 `COPY` + 一行 `RUN install-extensions.sh`，細節全在腳本內：

1. **版本表**（`name version sha256`，全部為 PHP 8.0 相容版本）：

   | 擴充 | 版本 | `package.xml` 最低 PHP |
   |---|---|---|
   | memcached | 3.4.0 | 7.0.0 |
   | imagick | 3.8.1 | 5.6.0 |
   | mcrypt | 1.0.9 | 7.2.0 |
   | zstd | 0.18.0 | 7.0 |
   | timezonedb | 2026.5 | 5.4.0 |
   | redis | 6.0.2 | 7.4.0 |

2. 逐一下載 `https://pecl.php.net/get/<name>-<version>.tgz`（`curl --retry 5`）並驗證 SHA256。
3. 解壓成 **`package.xml` 與原始碼同層**：

   ```sh
   tar -xzf <name>.tgz -C /usr/src/pecl/<name> --strip-components=1 "<name>-<version>"
   tar -xzf <name>.tgz -C /usr/src/pecl/<name> package.xml
   ```

4. 以**目錄路徑**取代套件名呼叫 `install-php-extensions`：
   它會讀 `package.xml` 取得 name/version，再執行
   `pecl install /usr/src/pecl/<name>/package.xml`，PEAR 相對該目錄驗證檔案，**不查 REST**。
   apt 依賴仍由 IPE 依擴充名稱自動安裝（例如 imagick → `libmagickwand-dev`）。
5. `install-php-extensions` 重試降為 **2 次**（`IPE_ATTEMPTS` 可覆寫）：
   REST 問題已從源頭消除，剩下的只可能是偶發網路錯誤。
6. 安裝完成後 `rm -rf /usr/src/pecl`，不把原始碼留在 image 層。

### 5.2 一併固定 `install-php-extensions`

原本用 `releases/latest/download/...`，安裝器會在無聲中改版（本次行為差異正是它挑到
`memcached 3.4.0` 後才去查 REST 的），與本專案「所有輸入都固定」的原則不一致。

改為固定版本 + 校驗：

```dockerfile
ADD --chmod=0755 --checksum=sha256:<hash> \
    https://github.com/mlocati/docker-php-extension-installer/releases/download/2.12.3/install-php-extensions \
    /usr/local/bin/
```

`--checksum` 讓 BuildKit 在下載後直接比對，不需要額外的 `RUN sha256sum`。

## 6. 驗證

| 項目 | 結果 |
|---|---|
| `sh -n scripts/install-extensions.sh` | ✅ |
| 六個 tarball 的 SHA256 | ✅ 逐一核對 |
| tarball 佈局（`package.xml` 在根、原始碼在 `<name>-<version>/`） | ✅ 六個皆符合 |
| 本機模擬全新 build（僅 PECL 層） | ✅ 見下 |
| 本機完整 build（`linux/amd64`，`mmhk/php-docker:8.0-fpm-local`） | ✅ 見下 |
| CI（amd64 + arm64） | ⏳ 待 `v8.0-fpm` 觸發 |

**本機完整 build 結果**（PHP 8.0.30 + 補丁 + 全部擴充）：

```
php 8.0.30
memcached 3.4.0   imagick 3.8.1   mcrypt 1.0.9
redis 6.0.2       zstd 0.18.0     timezonedb 2026.5
gd 8.0.30         opcache JIT tracing / 128M
Memcached OK / Imagick OK (ImageMagick 6.9.11-60) / zstd OK / Redis class OK
/usr/src 只剩 php.tar.xz（暫存目錄已清除）
```

**本機模擬方式**：以已建好的 `8.0-fpm-cve-test` 為基礎，先刪除 PECL registry
（`/usr/local/lib/php/.registry/.channel.pecl.php.net`）與六個 ini/so，再執行
`install-extensions.sh`。

結果：六個 tarball 下載 + SHA256 通過、`Checking package.xml of directory … good`、
imagick 的 apt 依賴自 `archive.debian.org` 正常安裝，最後 `php -m` 六個全部載入：

```
imagick  mcrypt  memcached  redis  timezonedb  zstd
```

**注意（重裝情境的假警報）**：若 registry 內仍有紀錄，PEAR 會回
`Ignoring installed package … / Nothing to install`，IPE 接著找不到 `.so` 而失敗。
全新 build 的 registry 是空的，不會發生；除錯時請先清 registry。

## 7. 檔案清單

| 路徑 | 說明 |
|---|---|
| `scripts/install-extensions.sh` | 新增；固定 tarball 安裝全部擴充 |
| `Dockerfile` | 移除 redis 專屬 ENV/RUN，改為 COPY + 執行腳本；固定 IPE 版本 |
| `AGENTS.md` | redis 專屬說明改為 PECL 通則 |
| `README.md` | 補 PECL 固定版本說明 |
| `docs/plans/php-8.0-cve-2026-109618-109619-patch.md` | 7.5 改寫為通則 |

## 8. 維護

- **升版單一擴充**：改 `scripts/install-extensions.sh` 的版本表；SHA256 取
  `https://pecl.php.net/get/<name>-<version>.tgz` 的 `sha256sum`；確認該版本
  `package.xml` 仍接受 PHP 8.0。
- **新增擴充**：先確認是否 bundled（第 3 節判準）。不是 bundled 就必須加進版本表；
  直接寫套件名會再次撞上 REST 問題。
- **升級 IPE**：換版本號與 `--checksum` 的 SHA256；升級後重跑一次本機模擬驗證。

## 9. 風險與回滾

| 風險 | 說明 / 對策 |
|---|---|
| 固定版本不自動取得安全性修復 | 需定期檢視 PECL 版本；升版流程見第 8 節 |
| PECL 舊版 tarball 下架 | 機率低；真的發生時改用 GitHub 對應 tag 或升版 |
| `--checksum` 需 BuildKit | 本專案已用 `ADD --chmod`，本來就要求 BuildKit |
| 回滾 | 本次變更集中於 `scripts/install-extensions.sh` 與 Dockerfile 單一段落，可直接 revert |
