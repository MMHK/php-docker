# PHP 7.4 擴充安裝方案（PECL 固定 tarball）

> 分支：`7.4-fpm`　｜　目標鏡像：`mmhk/php-docker:7.4-fpm`
> 狀態：**規劃完成，尚未改 Dockerfile**（版本、SHA256、PECL 安裝流程已實測，見 5.1/6.1）
> 參考：`php-8.0-extension-install.md`（8.0 分支已完成並驗證）
> 相關：`docs/plans/php-7.4-cve-2026-109618-109619-patch.md`（CVE 補丁方案）

---

## 1. 問題

7.4 的 Dockerfile 目前只對 **redis** 做了單點繞道（自行下載固定 tarball、解壓成
`package.xml` 與原始碼同層、以目錄路徑交給 `install-php-extensions`），其餘 PECL 擴充
（`memcached`、`imagick`、`mcrypt`、`timezonedb`）仍以**套件名**交給
`install-php-extensions`，也就是仍會向 PEAR REST 查版本。

同一段 Dockerfile 還有兩個違反「所有輸入都固定」原則的地方：

1. `install-php-extensions` 取自 `releases/latest/download/...`，安裝器會無聲改版；
2. shell 層重試 5 次／間隔 10 秒，對**永久性**失敗（第 2 節）完全無效，只是把錯誤
   延後約 40 秒才爆。

8.0 分支已實際踩到（2026-10 CI）：

```
Package "memcached" Version "3.4.0" does not have REST xml available
install-php-extensions failed after 5 attempts
```

7.4 目前「看起來正常」，只是因為上次建置時那幾個套件剛好走通；通道層級的問題
一旦出現，7.4 會以完全相同的方式失敗（redis 當初就是這樣被單點修掉）。

## 2. 根因

- `pecl.php.net`（BunnyCDN）對 PEAR 的 REST metadata 回應帶 `content-encoding: gzip`，
  而 PEAR 的 HTTP client **不會解壓縮**，XML 解析因此失敗：
  ```
  Debug: Invalid xml downloaded from "https://pecl.php.net/rest/p/<pkg>/info.xml":
         XML Error: 'Not well-formed (invalid token)' on line '1'
  ```
- 這是**內容可讀性**問題，不是連線問題：同一 URL 用 `curl --compressed` 取回的是合法
  XML，重試結果必然相同。
- 只有「需要向 channel 查版本／下載路徑」的擴充受影響；bundled 擴充由
  `docker-php-ext-install` 直接從 `/usr/src/php.tar.xz` 編譯，完全不碰 REST。

## 3. 影響範圍：整個 PECL channel

**判準**：PHP 7.4.33 原始碼樹內有 `/usr/src/php/ext/<name>/config.m4` → bundled；
沒有 → 只能走 PECL，就會踩到。

7.4 目前安裝 **20 項**（與 8.0 的 24 項不同：7.4 沒有 `zstd`、`gmp`、`pgsql`、
`pdo_pgsql`）：

| 類別 | 數量 | 擴充 | 受影響 |
|---|---|---|---|
| PECL | 5 | `memcached` `imagick` `mcrypt` `redis` `timezonedb` | ✅ 必須固定 tarball |
| bundled | 14 | `gd` `gettext` `mysqli` `pdo_mysql` `opcache` `exif` `bcmath` `soap` `sockets` `zip` `snmp` `bz2` `shmop` `ffi` | ❌ |
| 特殊 | 1 | `@composer`（getcomposer.org 下載） | ❌ |

> 另有 `sodium`，在建 PHP 階段以 `docker-php-ext-enable sodium` 啟用，不經 IPE。
>
> 判準可隨時重查：
> `tar -tf /usr/src/php.tar.xz | sed -n 's|^php-7.4.33/ext/\([^/]*\)/config.m4$|\1|p'`

## 4. 方案比較

| 方案 | 說明 | 結論 |
|---|---|---|
| A. 加重試 / backoff | 失敗是永久性的（伺服器回 200，內容壞掉） | ❌ 無效 |
| B. 把 tarball URL 交給 `install-php-extensions` | IPE 支援 URL，但 PECL tarball 頂層同時有 `package.xml` 與 `<name>-<version>/`，`getPackageSource` 會退回暫存目錄，PEAR 驗證相對路徑檔案時失敗；且無 SHA256 可驗 | ❌ |
| C. **自行下載固定 tarball，解壓成目錄後交給 IPE** | 完全繞過 channel；可固定版本與 SHA256；機制已在 redis 上驗證過 | ✅ **採用** |
| D. 自架 PECL mirror / 換 channel | 需額外服務與憑證 | ❌ 成本過高 |

## 5. 最終方案

### 5.1 新增 `scripts/install-extensions.sh`

沿用 8.0 分支的腳本（結構、錯誤處理、`IPE_ATTEMPTS` 覆寫機制一致），只調整版本表與
擴充清單。Dockerfile 只保留 `COPY` + 一次 `RUN install-extensions.sh`。

1. **版本表**（`name version sha256`）：7.4 與 8.0 可用**完全相同**的 tarball，
   因此 SHA256 直接沿用（已逐一驗證）：

   | 擴充 | 版本 | `package.xml` PHP 範圍 | SHA256（2026-10-22 實測） |
   |---|---|---|---|
   | memcached | 3.4.0 | 7.0.0 – （無上限） | `c163434eb0da97c8f45c7ad41d979d381f8b81c49402b1b90b063987fb37972e` |
   | imagick | 3.8.1 | 5.6.0 – （無上限） | `3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee` |
   | mcrypt | 1.0.9 | 7.2.0 – 8.6.0 | `2a9ef0817d3bf677f6d7baf8e325629a2758974735d8abad6566384788d424a5` |
   | timezonedb | 2026.5 | 5.4.0 – （無上限） | `affcad3175b7d2d3dde359ca2737addc8c8c95de355c2c73a2bab69bbbc2e012` |
   | redis | 6.0.2 | 7.2.0 – （無上限） | `01aeccb0e14f897fe56f0509be6e6991ff0ad459f9d34e95e4556d02699b9a03` |

   > 8.0 的 `zstd 0.18.0` 在 7.4 不使用，不列入。

   **已核對（本機，2026-10-22）**
   - 五個 `https://pecl.php.net/get/<name>-<version>.tgz` 重新下載，SHA256 與上表**逐一相符**，
     且與 8.0 分支 `scripts/install-extensions.sh` 內的值完全相同（同一份 tarball）。
   - 五個 tarball 佈局皆為：根目錄 `package.xml` + `<name>-<version>/` 原始碼
     （`tar -tzf` 逐一確認），符合 5.1 第 3 點的解壓方式。
   - `package.xml` 的 `<version><release>` 與檔名一致；PHP 範圍見上表。
   - **修正 8.0 文件的數據**：redis 6.0.2 的 `package.xml` 寫的是 `min 7.2.0`，
     不是 8.0 文件表格中的 7.4.0（7.4 仍可用，只是下限更低）。
   - 現有 `mmhk/php-docker:7.4-fpm-verify` 內實際安裝的版本正好是
     `memcached 3.4.0 / imagick 3.8.1 / mcrypt 1.0.9 / redis 6.0.2 / timezonedb 2026.5`
     —— 即 PECL channel 當時解析出的就是這五個版本，固定後行為不變，只是不再依賴 channel。

2. 逐一下載 `https://pecl.php.net/get/<name>-<version>.tgz`（`curl --retry 5`）並驗證 SHA256。
3. 解壓成 **`package.xml` 與原始碼同層**：
   ```sh
   tar -xzf <name>.tgz -C /usr/src/pecl/<name> --strip-components=1 "<name>-<version>"
   tar -xzf <name>.tgz -C /usr/src/pecl/<name> package.xml
   ```
4. 以**目錄路徑**取代套件名呼叫 `install-php-extensions`；IPE 讀 `package.xml` 取得
   name/version，再執行 `pecl install <dir>/package.xml`，PEAR 在該目錄驗證檔案，
   **不查 REST**。apt 依賴仍由 IPE 依擴充名稱自動安裝（imagick → `libmagickwand-dev` 等）。
5. 安裝清單（順序照現行 Dockerfile）：
   ```
   @composer gd /usr/src/pecl/memcached gettext /usr/src/pecl/imagick
   /usr/src/pecl/mcrypt mysqli /usr/src/pecl/redis pdo_mysql opcache exif
   bcmath soap sockets /usr/src/pecl/timezonedb zip snmp bz2 shmop ffi
   ```
6. `IPE_ATTEMPTS` 預設 **2**（REST 問題已從源頭消除，剩餘只可能是偶發網路錯誤）。
7. 安裝完成後 `rm -rf /usr/src/pecl`，不把原始碼留在 image 層。

### 5.2 一併固定 `install-php-extensions`

```dockerfile
ADD --chmod=0755 --checksum=sha256:9c26dd516b8147235c4e924c52e2f076fb2b3f278f5457e88918518ebfee9e01 \
	https://github.com/mlocati/docker-php-extension-installer/releases/download/2.12.3/install-php-extensions \
	/usr/local/bin/
```

- 已在本機下載 2.12.3 核對 SHA256，與上面一致；該版本的支援清單含 `704`（PHP 7.4），
  行為與目前 `latest` 相同。
- `--checksum` 讓 BuildKit 在下載後直接比對，不需額外 `RUN sha256sum`。

### 5.3 Dockerfile 變更

| 動作 | 內容 |
|---|---|
| 刪除 | `ENV REDIS_VERSION` / `REDIS_URL` / `REDIS_SHA256` 三行 |
| 刪除 | 現行 base layer 那一大段 `RUN apt-get update && ... until install-php-extensions ...` |
| 改為 | `ADD --chmod=0755 --checksum=...`（固定 IPE 2.12.3） |
| 改為 | `COPY --chmod=0755 scripts/install-extensions.sh /usr/local/bin/` |
| 改為 | base layer 只留：`apt-get update` → `apt-get install -y --no-install-recommends tzdata sudo` → `install-extensions.sh` → `rm -rf /var/lib/apt/lists/*` |

保留 `sudo`：本 image 一向提供它（entrypoint 未使用，屬既有對外行為），不在本次變更範圍。

### 5.4 與 8.0 方案的差異

| 項目 | 8.0 | 7.4 |
|---|---|---|
| PECL 擴充數 | 6（多 `zstd`） | 5 |
| bundled 清單 | 多 `gmp`、`pgsql`、`pdo_pgsql` | 見 5.1 第 5 點 |
| PHP 版本 | 8.0.30 | 7.4.33（EOL，已套 CVE backport） |
| IPE / 版本表 | 2.12.3 / 同上 | 相同（可直接複用） |

## 6. 驗證計畫

| 項目 | 方法 | 通過標準 |
|---|---|---|
| 腳本語法 | `sh -n scripts/install-extensions.sh` | 無錯誤 |
| 五個 tarball SHA256 | 下載後 `sha256sum -c` | ✅ 已驗證（2026-10-22，5/5 相符） |
| tarball 佈局 | `tar -tzf` 檢查 `package.xml` 在根、原始碼在 `<name>-<version>/` | ✅ 已驗證（5/5 符合） |
| 5 個 PECL 在 7.4 實際編譯 + 載入 | 在 `7.4-fpm-verify` 容器內清 registry 後跑 5.1 步驟 2–4 | ✅ 已驗證（見下方） |
| 完整建置 | `docker build --platform linux/amd64 -t mmhk/php-docker:7.4-fpm-local .` | 成功，無 reject / 無 REST 查詢 |
| 版本 | `php -r 'foreach (["memcached","imagick","mcrypt","redis","timezonedb"] as $e) echo $e," ",phpversion($e),PHP_EOL;'` | 3.4.0 / 3.8.1 / 1.0.9 / 6.0.2 / 2026.5 |
| 擴充齊全 | `php -m` | 20 項 + `sodium`、`Zend OPcache` 皆在 |
| 功能冒煙 | `Memcached` / `Imagick` / `Redis` 類別可建立 | 無 fatal |
| 暫存清理 | `ls /usr/src` | 只剩 `php.tar.xz` |
| 補丁仍在 | `nm -D /usr/local/bin/php` | `zend_mm_safe_error_ex`、`zend_new_array_singleton` |
| arm64 | GitHub Actions 原生 runner | 建置成功並推送 |

**注意（重裝情境的假警報）**：若 registry 內仍有紀錄，PEAR 會回
`Ignoring installed package … / Nothing to install`，IPE 接著因找不到 `.so` 而失敗。
全新 build 的 registry 是空的，不會發生；除錯時請先清
`/usr/local/lib/php/.registry/.channel.pecl.php.net`。

**除錯實測補充**：清 registry 時也要一併刪掉對應的 `conf.d/*<name>*.ini`
（本 image 的 memcached ini 名為 `xx-php-ext-memcached.ini`，不是 IPE 的
`docker-php-ext-*.ini`），否則 IPE 會以 `Module '<name>' already loaded` 判定失敗。

### 6.1 已完成的模擬驗證（2026-10-22）

在既有的 `mmhk/php-docker:7.4-fpm-verify`（PHP 7.4.33 + 已套補丁）容器內，以 root
清掉 5 個 PECL 的 registry/ini/so，再執行 5.1 步驟 2–4（只裝這 5 個，不重編 PHP）：

```
>>> staging memcached 3.4.0      sha256sum: OK
>>> staging imagick 3.8.1        sha256sum: OK
>>> staging mcrypt 1.0.9         sha256sum: OK
>>> staging timezonedb 2026.5    sha256sum: OK
>>> staging redis 6.0.2          sha256sum: OK

install ok: channel://pecl.php.net/memcached-3.4.0     ... ok.
install ok: channel://pecl.php.net/imagick-3.8.1       ... ok.
install ok: channel://pecl.php.net/mcrypt-1.0.9        ... ok.
install ok: channel://pecl.php.net/timezonedb-2026.5   ... ok.
install ok: channel://pecl.php.net/redis-6.0.2         ... ok.

memcached    3.4.0
imagick      3.8.1
mcrypt       1.0.9
redis        6.0.2
timezonedb   2026.5
```

- 全程**沒有任何 REST 查詢**（沒有 `does not have REST xml available`），證明目錄路徑
  確實繞過 channel。
- imagick 需要的 `libmagickwand-dev`、memcached 需要的 `libmemcached-dev` 等 apt 依賴
  由 IPE 自行從 `archive.debian.org` 安裝成功（bullseye EOL 設定已就位）。
- 因此剩下的不確定性只在於完整 build 的其餘 14 個 bundled 擴充（與本次改動無關）。

## 7. 檔案清單

| 路徑 | 說明 |
|---|---|
| `scripts/install-extensions.sh` | 新增；固定 tarball 安裝全部擴充 |
| `Dockerfile` | 移除 redis 專屬 ENV/RUN，改為固定 IPE + COPY + 執行腳本 |
| `README.md` | 補 PECL 固定版本與 IPE 固定版本說明 |
| `docs/plans/php-7.4-extension-install.md` | 本文件 |

（7.4 分支沒有 `AGENTS.md`，不需要同步。）

## 8. 維護

- **升版單一擴充**：改 `scripts/install-extensions.sh` 版本表；SHA256 取
  `https://pecl.php.net/get/<name>-<version>.tgz` 的 `sha256sum`；確認該版本
  `package.xml` 仍接受 PHP 7.4。
- **新增擴充**：先確認是否 bundled（第 3 節判準）；不是 bundled 就必須加進版本表，
  直接寫套件名會再撞上 REST 問題。
- **升級 IPE**：換版本號與 `--checksum` 的 SHA256；升級後重跑一次本機驗證。

## 9. 風險與回滾

| 風險 | 說明 / 對策 |
|---|---|
| 固定版本不自動取得安全性修復 | 需定期檢視 PECL 版本；升版流程見第 8 節 |
| PECL 舊版 tarball 下架 | 機率低；改用 GitHub 對應 tag 或升版 |
| `--checksum` 需 BuildKit | 本專案已用 `ADD --chmod`，本來就要求 BuildKit |
| 7.4 為 EOL，新 IPE 可能停止支援 | 已固定 2.12.3（支援 704），不隨 `latest` 漂移 |
| 回滾 | 變更集中於 `scripts/install-extensions.sh` 與 Dockerfile 單一段落，可直接 revert |

## 10. 發佈

改動合併後需重建鏡像才會生效，而 CI 只由 `v*` tag 觸發：

1. 目前 `v7.4-fpm` tag 指向 `0658ad3`（已推送）。要重跑發佈需
   `git tag -d v7.4-fpm && git push --delete origin v7.4-fpm`，再對新 commit 重打同名 tag
   並 `git push origin v7.4-fpm`（會覆寫 Docker Hub 上的 `7.4-fpm`）。
2. 或改用新 tag（例如 `v7.4-fpm-ext`）避免動到既有 tag；workflow 推送的 image tag
   仍是固定的 `7.4-fpm`，不受 git tag 名稱影響。

決策待確認：是否允許覆寫已發佈的 `v7.4-fpm`。
