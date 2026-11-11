# PHP Runtime CA Trust Fix — eMudhra 憑證洩露事件

> **AI 生成聲明 (AI-Generated Declaration)**：本文件由 AI 依需求分析自動生成，內容尚未經人類審核。僅供參考，需人類 review + confirm 後方可執行。
> **Review Status**: ⚪ Pending
> **Reviewed By**: (人工填寫姓名/日期)

**Created**: 2026-11-09
**Status**: 🟡 In Progress
**Human Review**: ⚪ Pending
**Priority**: High

---

## Background & Goals

2026-10-19 揭露印度 CA **eMudhra** 的 8 張 intermediate CA 私鑰可被推導（金鑰隨機性不足），攻擊者可據此簽發**任意網域**的 TLS 憑證。

本 repo 的 image 實測狀況：

| Image | Base | ca-certificates | `emSign ECC Root CA - G3` | `Comodo_AAA_Services_root` | 4 個 checker host |
|---|---|---|---|---|---|
| `mmhk/php-docker:7.4-fpm` | Debian 11 bullseye (archive) | `20250419~deb12u1~deb11u1` | 有 | 有 | `http=200`（VULNERABLE） |
| `mmhk/php-docker:8.0-fpm` | Debian 11 bullseye (archive) | `20250419~deb12u1~deb11u1` | 有 | 有 | `http=200`（VULNERABLE） |
| `mmhk/php-docker:8.3-fpm` | Debian 12 bookworm | `20250419~deb12u2` | 無 | 無 | `errno=60`（rejected） |

bullseye 已 EOL 並移入 `archive.debian.org`，`bullseye-security` 最新版本就是 `~deb11u1`（2025-04 的 Mozilla bundle，事件前），**不會有後續修補**。因此 7.4 / 8.0 必須自行處理。

### Goals

1. 讓 **PHP runtime**（ext/curl／Guzzle、PHP stream wrapper／SoapClient）拒絕這 8 張被攻破 intermediate 所簽出的憑證。
2. 使用 **curl 官方 CA extract**（Mozilla bundle，事件後版本），以 PHP ini pin 方式套用。
3. Build 可重現：固定日期版本檔 + SHA256 驗證。
4. 不改任何 application code。

### Non-Goals

- 不改系統 `/etc/ssl/certs/ca-certificates.crt`（`curl` CLI、Python、Node 等其他 runtime 不在本次範圍）。
- 不升級 PHP 版本或 OS base（PHP 7.4/8.0、bullseye 均已 EOL，屬獨立技術債）。
- 不處理 BEA mTLS client certificate（與本次 server cert 輪換無關）。

---

## Design Decisions

1. **Bundle 來源**：curl 官方 CA extract。
   - 版本：`cacert-2026-11-05.pem`（Mozilla as of 2026-11-05）
   - SHA256：`427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`
   - 大小 200,116 bytes；root 數 118。
   - 已實測：4 個 checker host 全部 `errno=60` rejected；內含 `emSign Root CA - G1`（非本次被攻破的 key，保留），不含 `emSign ECC Root CA - G3` 與 `Comodo_AAA`。

2. **取得方式**：**build-time 下載**（build 內 `curl` 抓 `https://curl.se/ca/cacert-2026-11-05.pem`）。
   - 以**固定日期檔**（非 `cacert.pem`）避免內容漂移。
   - 下載後以 **SHA256 驗證**，不符即讓 build 失敗。
   - 更新時只改 Dockerfile 內的 URL 與 SHA256。
   - 已知前提：base image 已內建 `curl` 與 `sha256sum`（已確認 7.4-fpm 內 `curl 7.74.0`）。

3. **套用方式**：PHP ini pin（不動系統 bundle）。
   - `curl.cainfo` → ext/curl 預設 `CURLOPT_CAINFO`（Guzzle `verify => true` 會沿用，已實測）。
   - `openssl.cafile` → PHP stream wrapper / `file_get_contents('https://…')` / `SoapClient`。
   - `zz-ca-pin.ini` 放 `/usr/local/etc/php/conf.d/`，`zz-` 確保最後載入。

4. **不改系統 bundle**：維持現有 package 行為，避免影響 image 內其他工具；若日後要連 CLI 也保護，另開任務。
   - 已知限制：程式碼顯式傳 `verify => 'path'` 或 `CURLOPT_CAINFO` 會繞過 ini（本專案 BEA 為 `verify => true`，受控）。

---

## Tasks

| # | Task | Status | Sub Agent | Notes |
|---|------|--------|-----------|-------|
| 1 | 確認分支範圍：`7.4-fpm` / `8.0-fpm`（必改）、`8.3-fpm`（一致性，選改） | ⬜ Pending | — | `8.0-fpm` 分支 Dockerfile 目前缺 bullseye archive 修正，需先確認能否 build |
| 2 | Dockerfile：build-time 下載 `cacert-2026-11-05.pem` 並以 SHA256 驗證 | ⬜ Pending | — | `curl -fsSL` + `sha256sum -c`；失敗即 build fail |
| 3 | 新增 `zz-ca-pin.ini`（`curl.cainfo` + `openssl.cafile`） | ⬜ Pending | — | 不放 `openssl.capath` |
| 4 | Dockerfile：`COPY` ini 至 `conf.d/`，確認 bundle 路徑與權限 644 | ⬜ Pending | — | 必須在 `USER www-data` 之前 |
| 5 | README 補充：bundle 來源、更新週期、驗證指令 | ⬜ Pending | — | 每季 rebuild 並更新日期檔 |
| 6 | Build 驗證：FPM ini 生效、4 個 checker host rejected、BEA baseline `verify=0` | ⬜ Pending | — | 用 temp container |
| 7 | 整合 smoke test（BEA、其他 payment、mail、Xero、WhatsApp、address formatter 等） | ⬜ Pending | — | 確認沒有服務依賴被移除的舊 root（如 AAA） |
| 8 | 多架構 build、tag、推送、部署與回滾 | ⬜ Pending | — | compose 指定 amd64/arm64 |
| 9 | （選配）系統 bundle 同步硬化，覆蓋 CLI/其他 runtime | ⬜ Pending | — | 另一階段，不在本次 |

## Implementation Sketch

```dockerfile
# Dockerfile（7.4 / 8.0；8.3 可選）
# 下載 curl 官方 CA bundle（固定日期版）並驗證 SHA256
RUN curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
      https://curl.se/ca/cacert-2026-11-05.pem \
      -o /usr/local/etc/ssl/certs/curl-cacert-2026-11-05.pem \
 && echo "427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285  /usr/local/etc/ssl/certs/curl-cacert-2026-11-05.pem" \
    | sha256sum -c - \
 && chmod 644 /usr/local/etc/ssl/certs/curl-cacert-2026-11-05.pem

COPY zz-ca-pin.ini /usr/local/etc/php/conf.d/zz-ca-pin.ini
```

```ini
; zz-ca-pin.ini
curl.cainfo = /usr/local/etc/ssl/certs/curl-cacert-2026-11-05.pem
openssl.cafile = /usr/local/etc/ssl/certs/curl-cacert-2026-11-05.pem
```


## Verification

1. `php-fpm -i | grep -E "curl.cainfo|openssl.cafile"` 顯示 pinned 路徑。
2. 4 個 checker host（direct / AAA / 兩種 no-CT）全部 `errno=60`。
3. `https://api.hkbea.com/` baseline：`errno=56`、`verify=0`（mTLS alert 屬正常）。
4. 應用冒煙：Guzzle 呼叫 BEA / 其他 HTTPS 服務正常。
5. 反向驗證：暫時指回舊 bundle，應重現 `http=200`，確認測試有效。

## Risks & Mitigations

| 風險 | 影響 | 對策 |
|---|---|---|
| bundle root 由 150 減至 118，可能刪掉某些舊服務依賴的 root（如 AAA） | 連線失敗 | Task 7 全量 smoke test；必要時改 CA-scoped bundle |
| bundle 快照過期 | 新 root 不生效 | 每季 rebuild、更新日期檔與 SHA256 |
| build-time 依賴 curl.se／CI 網路 | build 失敗 | 固定日期 URL + `--retry 3`；必要時暫時改為 vendor 或內部 mirror |
| 應用顯式指定 CA 路徑 | ini 被繞過 | 盤點 code；本專案 BEA 不受影響 |
| 非 PHP runtime 仍脆弱 | CLI/Python/Node 可被冒充 | 另開系統層任務（Task 9） |
| bullseye / PHP 7.4 / 8.0 EOL | 其他 CVE 無修補 | 中長期遷移到 bookworm 或 8.3+ |

## Rollback

- 部署層：切回上一個 image tag（`mmhk/php-docker:7.4-fpm` / `8.0-fpm` 舊 digest）。
- Repo 層：revert 本次 commit（移除 `zz-ca-pin.ini` 與 Dockerfile 內的下載 `RUN` 行）。

## Review Log

| Date | Reviewer | Findings | Action Taken |
|------|----------|----------|--------------|
| — | — | — | — |

## Notes

- 8.3-fpm（bookworm）目前已安全；是否一併 pin 以保持三個 image 行為一致，需人類決定。
- 7.4/8.0 分支 Dockerfile 有差異（`8.0-fpm` 缺 archive 源修正），實作時需逐分支確認，不可直接 cherry-pick。
