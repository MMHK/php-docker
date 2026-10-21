# CVE-2026-109618 / CVE-2026-109619 發布門禁

PHP 核心未授權 RCE（代號 **PHP2Shell**，CVSS 4.0 9.2），影響 PHP 5.4.0 起的預設配置。
`release.yml` 在打 `v*` tag 時會先跑這裡的門禁，失敗則不會推鏡像。

| 檔案 | 用途 | 層級 |
|---|---|---|
| `cve-gate.php` | 版本/patch 身分 + 配置殘留 | L0 / L1 |
| `oom-semantics.php` | OOM 語義回歸（patch 改變了 OOM 行為） | L2 |

## 修復版本

`8.2.35` / `8.3.36` / `8.4.27` / `8.5.12`。
`7.4` / `8.0` / `8.1` 已 EOL，上游只提供最小源碼 backport 分支，**不發布版本號**。

## 用法

```bash
# 本地（先 build 或指定任意鏡像）
docker run --rm -v "$PWD/scripts:/gate:ro" mmhk/php-docker:8.0-fpm php /gate/cve-gate.php
docker run --rm -v "$PWD/scripts:/gate:ro" mmhk/php-docker:8.0-fpm php /gate/oom-semantics.php

# 只驗證判定邏輯（不接觸執行環境），CI 每次都會跑
docker run --rm -v "$PWD/scripts:/gate:ro" mmhk/php-docker:8.0-fpm php /gate/cve-gate.php --self-test
```

`--self-test` 覆蓋 8.2/8.3/8.4/8.5 的邊界版本、7.4/8.0/8.1 的 EOL 判定、未知分支，
以及證明文件的分支聲明匹配（含 `7.40` 這類前綴誤判）。

## 官方修復版鏡像狀態（2026-10-22）

Docker Hub 上 `8.2.35` / `8.3.36` / `8.4.27` / `8.5.12` 的 tag 已存在，
但 manifest index 目前是空的（`{"manifests":[]}`），`docker pull` 會報
`no matching manifest for linux/amd64`。因此「升到官方修復版鏡像」這條路
目前無法實測，只能先用 `--self-test` 證明判定邏輯正確；
等官方 index 補齊後，同一個 gate 直接對新鏡像跑即可，無需改腳本。

PowerShell 請改用絕對路徑：

```powershell
docker run --rm -v "D:/projects/php-docker/scripts:/gate:ro" mmhk/php-docker:8.0-fpm php /gate/cve-gate.php
```

## 退出碼

| 碼 | 含義 |
|---|---|
| `0` | 通過 |
| `1` | 版本低於該分支的修復版（仍受影響） |
| `2` | EOL 分支且無 backport 證明 —— 預設 fail-closed |
| `3` | 配置不滿足（L1） |

`CVE_GATE_MODE=warn` 只告警不阻斷，僅供應急；CI 會把偏離寫進日誌。

## 現狀

`Dockerfile` 以官方 **PHP 8.0.30** 原始碼為基底，套用
`patches/php-8.0-CVE-2026-109618-109619.patch`（等同 php-src 分支
`PHP-8.0-CVE-2026-109618-109619` 的 commit
`82f8f31b16a035c1b67cc253e79f7cc288f4cc20`），並 COPY
`cve-2026-109618-109619.patched` 提供 L0 所需的 backport 證明，因此門禁預期通過。
二進位已確認含 `zend_mm_safe_error_ex` 與 `zend_new_array_singleton`（`nm -D`）。

若之後有人把基礎鏡像改回 `php:8.0-fpm-bullseye`（8.0 自 2023 年 EOL，官方不會有修復版），
門禁會以 `2` 失敗。屆時只有兩條路：

1. **升基礎鏡像**到 `php:8.2/8.3/8.4-fpm` 的修復版 tag，然後跑完整 L2 回歸。
2. **保留自建**（官方 8.0.30 原始碼 + 補丁）：確認分支/commit 正確，且證明文件所有欄位齊全。

門禁只驗證「聲明」，**不驗證聲明為真** —— commit 是否實際合入仍由建置流程負責。
證明文件格式（目前由 `cve-2026-109618-109619.patched` 提供，Dockerfile 已 COPY 到
`/usr/local/etc/php/`）：

```text
CVE-2026-109618 / CVE-2026-109619 patched
base: php-8.0.30 official release source
patch: php-src branch PHP-8.0-CVE-2026-109618-109619
commit: <40 位 commit SHA>
```


## PHP 7.4 / 8.0 兼容性

兩個 EOL 分支都只能靠源碼 backport，驗證方式完全一致：

| 項目 | 7.4 | 8.0 | 說明 |
|---|---|---|---|
| 腳本語法基線 | 7.4 | 7.4-safe | 刻意不用 `match` / `str_contains` / 命名參數 |
| 版本閘門 | 無官方修復版 → 必須有證明文件 | 同左 | 兩者都走退出碼 `2` 的 fail-closed 分支 |
| 分支聲明 | `PHP-7.4-CVE-...` | `PHP-8.0-CVE-...` | 補丁 commit 不同，**不可共用同一份證明文件** |
| OOM 語義回歸 | 適用 | 適用 | 兩分支的 OOM 修復語義一致 |
| `fatal_error_backtraces` | N/A | N/A | 僅 PHP 8.5 存在該路徑 |
| `opcache.jit*` | 無效（PHP 8+ 才有） | 有效 | 7.4 鏡像沿用 `opcache.ini` 時 JIT 段是 no-op，建議分支化 |

因此**每個分支各放一份證明文件**，COPY 到同一個容器內路徑：

```text
cve-2026-109618-109619.php74.patched   -> source: php-src branch PHP-7.4-CVE-2026-109618-109619
cve-2026-109618-109619.php80.patched   -> source: php-src branch PHP-8.0-CVE-2026-109618-109619
```

```dockerfile
COPY cve-2026-109618-109619.php80.patched /usr/local/etc/php/cve-2026-109618-109619.patched
```

門禁會檢查聲明分支與實際運行分支是否一致，避免 8.0 的補丁被誤用到 7.4 鏡像。

門禁對鏡像本身無耦合，只要 `docker build` 出來的鏡像能執行 `php` 即可；
若 7.4 與 8.0 使用兩份 Dockerfile，把 release workflow 的建置步驟改成 matrix
（例如 `Dockerfile.php74` / `Dockerfile.php80`）並對每個鏡像各跑一次門禁即可。

## 8.0 / 7.4 的驗證模式（與 8.2+ 不同）

8.2+ 只認版本號；EOL 分支沒有可信版本號，因此走「三件套 + 行為回歸」：

| 步驟 | 檢查內容 | 依據 |
|---|---|---|
| 1 | 證明文件含兩個 CVE ID、40 位 commit、當前分支聲明 | `BACKPORT_MARKER` |
| 2 | 該 commit 必須等於 `scripts/cve-expected-patches.json` 釘住的值 | 倉庫審查紀錄，防構建漂移 |
| 3 | **二進位含 patch 痕跡**（`zend_mm_safe_error_ex`） | ELF 動態符號表，**不依賴自我聲明** |
| 4 | `oom-semantics.php` 五項回歸通過 | patch 改變了 OOM 語義 |

第 3 步是關鍵：`PHP-8.0-CVE-2026-109618-109619` 的單一 commit `82f8f31b`
同時修兩個 CVE，並新增 `ZEND_API` 函式 `zend_mm_safe_error_ex`。
實測結果：官方 `php:8.0-fpm` / `php:7.4-cli` 的 `php` 與 `php-fpm` 二進位
都是 0 命中，修補後鏡像為 1 命中。因此「只換 marker 不換二進位」會被擋下。

**殘留缺口**：這證明「該 commit 的程式碼確實在產物裡」，不等於逐條攻擊路徑
都被驗證。完整結論仍需 L3 PoC 實打（攻擊失敗）；建議做成獨立的
`security-acceptance` 流程，而不放進 release 門禁。

## L1 檢查項

- `memory_limit` 不得為 `-1`（那是 CVE-2026-109618 的應急緩解）
- `post_max_size` / `upload_max_filesize` 有界且彼此一致
- `session.upload_progress.enabled` 開啟時告警（未修復時是攻擊路徑；官方也建議不需要就關）
- 池內額外 `php_admin_value/flag` 覆蓋需人工確認（early diagnostic 是 CVE-2026-109619 的 consumer）
- `pm.max_requests` 建議設低值（縮短 stale state 的跨請求生命週期）

## 尚未自動化的部分

L3 安全驗收（公開 PoC 基線 + S1–S6 定向探針）需要獨立、無出網的隔離環境，
不適合放在 release workflow；建議另建 `security-acceptance` 手動 workflow 或本地執行。
