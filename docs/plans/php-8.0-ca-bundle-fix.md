# PHP 8.0 Runtime CA Bundle 修正方案（eMudhra 憑證洩露）

> 分支：`8.0-fpm`　｜　目標鏡像：`mmhk/php-docker:8.0-fpm`
> 狀態：已依方案 B 實作，建置與 6.1／6.2 初步驗證通過（尚未人工 review 確認，6.3 未執行）
> 相關：`docs/plans/php-8.0-cve-2026-109618-109619-patch.md`、`docs/plans/php-8.0-extension-install.md`
> 同源修正（已實作）：`7.4-fpm` 分支 commit `9c67274`

---

## 1. 問題

2026-10-19 揭露印度 CA **eMudhra** 的 8 張 intermediate CA 私鑰可被推導（金鑰隨機性不足），
攻擊者可簽發任意網域的 TLS 憑證（CVE-2026-111943 / CVE-2026-111944）。

本分支的 `debian:bullseye-slim` 基於 Debian 11；`bullseye-security` 已移入
`archive.debian.org`，其 `ca-certificates` 停在事件前的 Mozilla bundle，
**不會再有修補**。因此 PHP runtime 的信任鏈需自行更新。

影響面（PHP 8.0 runtime）：

| 使用端 | 受影響的設定 |
|---|---|
| ext/curl（Guzzle `verify => true`） | `curl.cainfo` |
| PHP stream wrapper（`file_get_contents('https://…')`） | `openssl.cafile` |
| `SoapClient`（HTTPS WSDL） | `openssl.cafile` |

> 注意：本分支以原始碼編譯 PHP（`--with-curl`），其 ext/curl 仍讀取同一組 ini，
> 修正方式與 binary 版本相同。

---

## 2. 目標與約束

| 項目 | 要求 |
|---|---|
| 修補完整性 | PHP runtime 不再信任被攻破的 eMudhra intermediate |
| 隔離性 | **不改** 系統 `/etc/ssl/certs/ca-certificates.crt`（CLI curl / python 不在本次範圍） |
| 可重現性 | bundle 以固定日期檔 + SHA256 驗證（沿用本分支既有的 pin 慣例） |
| 可回滾 | 移除 ini / 下載層即可回到原行為 |
| 不改 application code | 只用 PHP ini pin |

---

## 3. 方案比較

| 方案 | 說明 | 結論 |
|---|---|---|
| A. 動態 `cacert.pem`、無校驗 | 與 `7.4-fpm` 目前實作一致 | ⚠️ 可接受但不可重現；不建議在 8.0 沿用 |
| B. **固定日期檔 + SHA256** | `cacert-YYYY-MM-DD.pem`，build 時校驗 | ✅ **建議採用**，符合本分支的 pin 風格 |
| C. 覆蓋系統 CA bundle | 直接取代 `/etc/ssl/certs/…` | ❌ 影響面過大，已否決 |

**為何選 B**

1. 本分支所有外部輸入都已 pin：`PHP_SHA256`、`PHP_CVE_PATCH_SHA256`、
   `install-php-extensions` 的 `ADD --checksum`、PECL 的 `name version sha256` 表。
   動態 bundle 會是唯一的例外。
2. 固定日期檔可讓「目前信任哪一版 Mozilla bundle」在檔名與 Dockerfile 一目了然。
3. 與 `7.4-fpm` 的原始規劃（`docs/plans/2026-11-09-emudhra-ca-bundle-fix.md`）一致；
   7.4 目前落地的動態版本可在後續對齊。

---

## 4. 已驗證的 bundle 數據

2026-11-11 實測 `https://curl.se/ca/cacert-2026-11-05.pem`：

| 項目 | 值 |
|---|---|
| SHA256 | `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285` |
| 大小 | 200,116 bytes |
| 憑證數 | 118 |
| `grep -i emudhra` | 0 筆（已移除） |

---

## 5. 實作設計

### 5.1 Dockerfile

在 base layer（`install-extensions.sh`）之後、config layer 之前新增：

```dockerfile
# CA bundle layer
# Debian bullseye 已 EOL，apt 的 ca-certificates 停在事件前版本；
# 以 curl 官方固定日期 bundle 取代，供 PHP runtime 使用（不改系統 bundle）。
RUN set -eux; \
	curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
		-o /usr/local/share/ca-certificates/cacert-2026-11-05.pem \
		https://curl.se/ca/cacert-2026-11-05.pem; \
	echo "427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285 */usr/local/share/ca-certificates/cacert-2026-11-05.pem" \
		| sha256sum -c -; \
	chmod 0644 /usr/local/share/ca-certificates/cacert-2026-11-05.pem
```

並在既有 `COPY` 區塊新增：

```dockerfile
COPY ca-bundle.ini /usr/local/etc/php/conf.d/ca-bundle.ini
```

- 依賴前提已滿足：`curl` 與 `sha256sum`（coreutils）在第 59-67 行的 runtime deps 已安裝。
- 放在 `USER www-data` 之前，檔案為 root 擁有、644 可讀。

### 5.2 ca-bundle.ini（新增檔）

```ini
; PHP runtime CA bundle（eMudhra 憑證洩露應急）
; 來源：https://curl.se/docs/caextract.html（Mozilla bundle，curl 專案維護）
; 更新方式：改 Dockerfile 的日期檔 URL 與 SHA256，並同步本檔路徑。
; 系統 /etc/ssl/certs/ca-certificates.crt 維持不變，僅 PHP runtime 使用本 bundle。

openssl.cafile = /usr/local/share/ca-certificates/cacert-2026-11-05.pem
curl.cainfo = /usr/local/share/ca-certificates/cacert-2026-11-05.pem
```

- 檔名沿用 7.4 的 `ca-bundle.ini`，避免跨分支認知差異。
- 本映像 `conf.d/` 內其他 ini（`opcache.ini`、`zz-cve-*.ini`）不操作這兩個鍵，無覆寫風險。

### 5.3 檔案與路徑

| 類型 | 路徑 |
|---|---|
| CA bundle | `/usr/local/share/ca-certificates/cacert-2026-11-05.pem` |
| PHP ini | `/usr/local/etc/php/conf.d/ca-bundle.ini` |
| 系統 CA（不改） | `/etc/ssl/certs/ca-certificates.crt` |

---

## 6. 驗證

### 6.1 建置與靜態檢查

```bash
docker compose build
docker run --rm mmhk/php-docker:8.0-fpm php -i | grep -E "openssl.cafile|curl.cainfo"
# 兩者都應顯示 /usr/local/share/ca-certificates/cacert-2026-11-05.pem
docker run --rm mmhk/php-docker:8.0-fpm grep -ci emudhra /usr/local/share/ca-certificates/cacert-2026-11-05.pem
# 應為 0
```

### 6.2 執行期連線

```bash
# ext/curl
docker run --rm mmhk/php-docker:8.0-fpm php -r '$c=curl_init("https://www.google.com");curl_setopt($c,CURLOPT_RETURNTRANSFER,1);curl_setopt($c,CURLOPT_SSL_VERIFYPEER,1);var_dump(curl_exec($c)!==false, curl_error($c));'
# stream wrapper
docker run --rm mmhk/php-docker:8.0-fpm php -r 'var_dump(@file_get_contents("https://www.google.com")!==false);'
```

### 6.3 針對性與冒煙（沿用 7.4 事件的驗證項目）

- 4 個 checker host（direct / AAA / 兩種 no-CT）應 `errno=60` rejected。
- 若服務鏈依賴被移除的舊 root（如 `Comodo_AAA`），需跑一次應用冒煙
  （BEA、其他 payment、mail、Xero、WhatsApp、address formatter）。
- 反向驗證：暫時把 ini 指回舊系統 bundle，應重現可連線，確認測試有效。

> 本次尚未執行 6.3；完成前只能宣稱「初步驗證」。

---

## 7. 風險與對策

| 風險 | 影響 | 對策 |
|---|---|---|
| bundle root 由 150 減至 118，刪掉舊服務依賴的 root | 連線失敗 | 跑 6.3 冒煙；必要時改用 CA-scoped bundle |
| 固定日期快照過期 | 新 root 不生效 | 每季 rebuild、更新日期檔與 SHA256 |
| build-time 依賴 curl.se／CI 網路 | build 失敗 | `--retry 3 --proto '=https' --tlsv1.2`；必要時改內部 mirror |
| 應用顯式傳 `verify => 'path'` 或 `CURLOPT_CAINFO` | ini 被繞過 | 盤點 code；本專案 BEA 為 `verify => true`，受控 |
| 非 PHP runtime 仍脆弱 | CLI/Python/Node 可被冒充 | 另開系統層任務 |
| 8.0 EOL | 其他 CVE 無修補 | 中長期遷移 |

---

## 8. 實作任務

| # | Task | Status |
|---|------|--------|
| 1 | 新增 `ca-bundle.ini`（內容見 5.2） | ✅ Done |
| 2 | Dockerfile 新增 CA bundle 下載 + SHA256 校驗層 | ✅ Done |
| 3 | Dockerfile `COPY ca-bundle.ini` 至 `conf.d/` | ✅ Done |
| 4 | `docker compose build` 並跑 6.1 / 6.2 | ✅ Done |
| 5 | （選）6.3 針對性與應用冒煙 | ⬜ Pending |
| 6 | commit（`feat(docker): …`） | ⬜ Pending |
| 7 | 打 `v8.0-fpm` tag 觸發 CI 推送 | ⬜ Pending |

---

## 9. 回滾

- 部署層：切回上一個 `mmhk/php-docker:8.0-fpm` tag／digest。
- Repo 層：revert 本次 commit（移除 `ca-bundle.ini`、Dockerfile 的 CA layer 與 COPY 行）。

---

## 10. 待人工決定

1. 是否採用方案 B（固定日期 + SHA256），或先與 7.4 現況一致的方案 A。
2. 是否一併把 `7.4-fpm` 的動態 bundle 升級為固定日期 + SHA256，保持兩分支一致。
3. 是否把 6.3 的應用冒煙列入本次交付門檻。
