# PHP Runtime CA Bundle 更新 — eMudhra 憑證洩露應急實施記錄

> **AI 生成聲明 (AI-Generated Declaration)**：本文件由 AI 依需求分析與實際實施結果自動生成，內容尚未經人類審核。僅供參考，需人類 review + confirm 後方可視為正式記錄。
> **Review Status**: ⚪ Pending
> **Reviewed By**: (人工填寫姓名/日期)

**Created**: 2026-11-11
**Status**: 🟢 Implemented（待人工 review）
**Human Review**: ⚪ Pending
**Priority**: High
**Related**: `docs/plans/2026-11-09-emudhra-ca-bundle-fix.md`（原設計方案）

---

## Background & Goals

2026-10-19 揭露印度 CA **eMudhra** 的 8 張 intermediate CA 私鑰可被推導（金鑰隨機性不足），攻擊者可據此簽發**任意網域**的 TLS 憑證。

本 repo 的 `php:7.4-fpm-bullseye` base 使用 Debian 11 bullseye，已 EOL 並移入 `archive.debian.org`；`bullseye-security` 的 `ca-certificates` 停在 `~deb11u1`（2025-04 的 Mozilla bundle，事件前版本），**不會再有後續修補**。因此 PHP runtime 的 CA trust 必須自行處理。

### Goals

1. 讓 **PHP runtime**（ext/curl／Guzzle、PHP stream wrapper／`file_get_contents`、`SoapClient`）使用事件後的 Mozilla CA bundle。
2. 使用 **curl 官方 CA extract** 作為 bundle 來源，以 PHP ini pin 方式套用。
3. 不改任何 application code。
4. 驗證可重現、可回滾。

### Non-Goals

- 不改系統 `/etc/ssl/certs/ca-certificates.crt`（`curl` CLI、Python、Node 等其他 runtime 不在本次範圍）。
- 不升級 PHP 版本或 OS base（PHP 7.4、bullseye 均已 EOL，屬獨立技術債）。
- 不處理 BEA mTLS client certificate（與本次 server cert 輪換無關）。
- 不覆蓋系統 CA bundle（「直接 override system path」方案已評估並否決，維持 PHP runtime 獨立 bundle）。

---

## Design Decisions

1. **Bundle 來源**：curl 官方 CA extract（`https://curl.se/ca/cacert.pem`，Mozilla bundle）。
   - 實測下載當日大小 200,116 bytes；root 數 118。
   - 已驗證 bundle 內**不含** `eMudhra` 字樣憑證。

2. **取得方式**：**build-time 下載**（build 內 `curl` 抓取並寫入 image layer），無 runtime 網路依賴。

3. **套用方式**：PHP ini pin（不動系統 bundle）。
   - `curl.cainfo` → ext/curl 預設 `CURLOPT_CAINFO`（Guzzle `verify => true` 會沿用）。
   - `openssl.cafile` → PHP stream wrapper / `file_get_contents('https://…')` / `SoapClient`。
   - 組態檔放 `/usr/local/etc/php/conf.d/`。

4. **不改系統 bundle**：維持現有 package 行為，避免影響 image 內其他工具；若日後要連 CLI 也保護，另開任務。
   - 已知限制：程式碼顯式傳 `verify => 'path'` 或 `CURLOPT_CAINFO` 會繞過 ini（本專案 BEA 為 `verify => true`，受控）。

---

## Implementation (as built)

### 檔案配置

| 類型 | 路徑 |
|---|---|
| CA bundle | `/usr/local/share/ca-certificates/cacert.pem` |
| PHP ini | `/usr/local/etc/php/conf.d/ca-bundle.ini` |
| 系統 CA（未改） | `/etc/ssl/certs/ca-certificates.crt` |

### Dockerfile 片段

```dockerfile
# CA bundle layer
# Download latest Mozilla CA bundle from curl.se to mitigate eMudhra CA compromise (Oct 2026).
# Debian Bullseye is EOL and cannot receive ca-certificates updates via apt.
# The bundle is baked into the image at build time — no runtime network dependency.
RUN mkdir -p /usr/local/share/ca-certificates \
 && curl -fsSL https://curl.se/ca/cacert.pem -o /usr/local/share/ca-certificates/cacert.pem \
 && chmod 644 /usr/local/share/ca-certificates/cacert.pem

...

COPY ca-bundle.ini /usr/local/etc/php/conf.d/ca-bundle.ini
```

### ca-bundle.ini

```ini
; CA Bundle configuration for eMudhra CA compromise mitigation
; (CVE-2026-111943 / CVE-2026-111944)
;
; Source: https://curl.se/docs/caextract.html (Mozilla CA bundle, maintained by Daniel Stenberg)
; Maintainer: Update by re-running docker build; the bundle is baked into the image layer.

openssl.cafile = /usr/local/share/ca-certificates/cacert.pem
curl.cainfo = /usr/local/share/ca-certificates/cacert.pem

; Note: System CA bundle (/etc/ssl/certs/ca-certificates.crt) remains unchanged.
; Only PHP runtime uses this independent CA bundle.
```

---

## Tasks

| # | Task | Status | Sub Agent | Notes |
|---|------|--------|-----------|-------|
| 1 | 確認分支範圍（本次僅 `7.4-fpm`） | ✅ Done | — | 8.0 / 8.3 未動 |
| 2 | Dockerfile：build-time 下載 curl CA bundle | ✅ Done | — | 目前為動態 `cacert.pem`，未固定日期檔 |
| 3 | 新增 PHP ini（`curl.cainfo` + `openssl.cafile`） | ✅ Done | — | 檔名 `ca-bundle.ini` |
| 4 | Dockerfile：`COPY` ini 至 `conf.d/`，確認 bundle 權限 644 | ✅ Done | — | 在 `USER www-data` 之前 |
| 5 | Build 驗證：ini 生效、SSL 連線正常、bundle 無 eMudhra | ✅ Done | — | 見驗證報告 |
| 6 | 4 個 checker host（direct / AAA / no-CT）rejected 驗證 | ⬜ Pending | — | 本次未執行 |
| 7 | BEA baseline（`errno=56`、`verify=0`） | ⬜ Pending | — | 本次未執行 |
| 8 | 整合 smoke test（BEA、payment、mail、Xero、WhatsApp 等） | ⬜ Pending | — | 本次未執行 |
| 9 | 多架構 build、tag、推送、部署與回滾 | ⬜ Pending | — | 待維運執行 |
| 10 | SHA256 固定日期版本 + 校驗（見 Deviations） | ⬜ Pending | — | 建議補強 |

---

## Verification

完整測試數據見 `docs/2026-11-11-emudhra-ca-bundle-verification.md`。

摘要：

- `php -i` 顯示 `openssl.cafile` / `curl.cainfo` 均指向 pinned bundle。
- cURL 與 `file_get_contents` 對 `https://www.google.com` 均 SSL 驗證成功。
- bundle 大小 200,116 bytes、118 張 root，`grep -i emudhra` 無結果。

---

## Deviations from 2026-11-09 Plan

本次實作與原設計方案（`2026-11-09-emudhra-ca-bundle-fix.md`）存在以下差異，需人工確認是否需要補強：

| 項目 | 2026-11-09 設計 | 本次實作 | 影響 |
|---|---|---|---|
| Bundle 檔名 | 固定日期 `cacert-2026-11-05.pem` | 動態 `cacert.pem` | 內容可能漂移，build 不可重現 |
| 完整性校驗 | `sha256sum -c -` | 無 | 無法偵測下載內容被替換／截斷 |
| 存放路徑 | `/usr/local/etc/ssl/certs/` | `/usr/local/share/ca-certificates/` | 無功能差異，僅慣例不同 |
| ini 檔名 | `zz-ca-pin.ini`（最後載入） | `ca-bundle.ini` | 若其他 conf.d 檔覆寫同鍵，載入順序可能有差異 |
| 下載參數 | `--retry 3 --proto '=https' --tlsv1.2` | `-fsSL` | 無重試，build 較易因網路失敗 |

> 建議：若要符合原設計的可重現性與供應鏈安全要求，將 Dockerfile 改為固定日期檔 + SHA256 校驗，並把 ini 改名為 `zz-ca-pin.ini`。

---

## Risks & Mitigations

| 風險 | 影響 | 對策 |
|---|---|---|
| bundle root 由 150 減至 118，可能刪掉舊服務依賴的 root（如 AAA） | 連線失敗 | 執行 Task 6-8 全量 smoke test；必要時改 CA-scoped bundle |
| 動態 `cacert.pem` 內容漂移 | build 不可重現 | 改用固定日期檔 + SHA256 |
| build-time 依賴 curl.se／CI 網路 | build 失敗 | 加 `--retry 3 --proto '=https' --tlsv1.2`；必要時改 vendor／內部 mirror |
| 應用顯式指定 CA 路徑 | ini 被繞過 | 盤點 code；本專案 BEA 不受影響 |
| 非 PHP runtime 仍脆弱 | CLI/Python/Node 可被冒充 | 另開系統層任務 |
| bullseye / PHP 7.4 EOL | 其他 CVE 無修補 | 中長期遷移到 bookworm 或 8.3+ |

---

## Rollback

- 部署層：切回上一個 image tag／digest（`mmhk/php-docker:7.4-fpm` 舊版本）。
- Repo 層：revert 本次 commit（移除 `ca-bundle.ini` 與 Dockerfile 內的下載 `RUN` 行）。

---

## Review Log

| Date | Reviewer | Findings | Action Taken |
|------|----------|----------|--------------|
| — | — | — | — |

---

## Notes

- 本次僅涵蓋 `7.4-fpm`；`8.0-fpm`（同為 bullseye）與 `8.3-fpm`（bookworm，已安全）未同步處理。
- 檔案 `test-ssl.php` / `tests/verify-ca-bundle.php` 為驗證輔助腳本，非 runtime 依賴。
- 後續建議把 CA bundle 更新納入定期 rebuild（每季或安全事件觸發）。

---

## 附錄 A：快速部署

```bash
# 構建
docker build -t mmhk/php-docker:7.4-fpm-ca-fix .

# 驗證檔案與 ini
docker run --rm mmhk/php-docker:7.4-fpm-ca-fix ls -lh /usr/local/share/ca-certificates/cacert.pem
docker run --rm mmhk/php-docker:7.4-fpm-ca-fix php -i | grep -E "openssl.cafile|curl.cainfo"

# 標記與推送
docker tag mmhk/php-docker:7.4-fpm-ca-fix mmhk/php-docker:7.4-fpm
docker push mmhk/php-docker:7.4-fpm
```

## 附錄 B：維護與故障排除

**定期更新**：重新執行 `docker build` 即可取得最新 `cacert.pem`；建議每月或安全事件時重建並跑一次驗證報告中的測試。

**常見問題**

- SSL 驗證失敗：先確認 ini 是否被其他 `conf.d/*.ini` 覆寫（`php -i | grep -E "openssl.cafile|curl.cainfo"`）。
- 特定站點失敗：該站 CA 可能不在 Mozilla bundle，用 `openssl s_client -connect <host>:443 -showcerts` 檢查鏈。
- 構建下載失敗：確認容器內 `curl` 可用與外網連通，或暫時改用內部 mirror。

## 附錄 C：參考資料

- eMudhra 事件：https://blog.cloudflare.com/emudhra-certificate-compromise
- curl CA extract：https://curl.se/docs/caextract.html
- PHP OpenSSL 設定：https://www.php.net/manual/en/openssl.configuration.php
- PHP cURL 設定：https://www.php.net/manual/en/curl.configuration.php
