# PHP Runtime CA Bundle 更新驗證報告 — eMudhra 憑證洩露應急

- **文件日期**：2026-11-11
- **影響範圍**：`mmhk/php-docker:7.4-fpm` 之 PHP runtime HTTPS trust store（ext/curl、PHP stream wrapper、SoapClient）
- **嚴重度**：高（事件前 bundle 仍信任被攻破的 eMudhra intermediate CA）
- **狀態**：已實施並完成初步驗證；完整應用冒煙測試待補
- **相關文件**：`docs/plans/2026-11-09-emudhra-ca-bundle-fix.md`、`docs/plans/2026-11-11-emudhra-ca-bundle-implementation.md`

---

## 1. 驗證目的

確認 eMudhra CA 洩露應急修復已正確落實，且未破壞 PHP runtime 的正常 HTTPS 連線：

1. CA bundle 是否已下載並具備正確權限。
2. PHP ini 是否 pin 到獨立 bundle（不影響系統 bundle）。
3. PHP 的 cURL 與 stream wrapper 是否仍可完成 SSL 驗證。
4. bundle 內是否已移除/eMudhra 相關憑證。

---

## 2. 受測環境

| 項目 | 值 |
|---|---|
| Image | `mmhk/php-docker:7.4-fpm-ca-fix` |
| Image ID | `902d6c0bc2c8` |
| Base | `php:7.4-fpm-bullseye`（Debian 11，archive 源） |
| 執行身分 | `www-data` (uid 1000) |
| 測試日期 | 2026-11-11 |

---

## 3. 驗證項目與結果

| # | 項目 | 指令／方式 | 結果 |
|---|---|---|---|
| 1 | CA bundle 檔案存在 | `ls -lh /usr/local/share/ca-certificates/cacert.pem` | ✅ 196K，`-rw-r--r-- root root` |
| 2 | PHP ini 生效 | `php -i \| grep -E "openssl.cafile\|curl.cainfo"` | ✅ 兩者均指向 pin 路徑 |
| 3 | cURL SSL 連線 | `curl_init('https://www.google.com')` + `VERIFYPEER=true` | ✅ HTTP 200 |
| 4 | stream SSL 連線 | `file_get_contents` + `verify_peer/verify_peer_name` | ✅ 成功 |
| 5 | eMudhra 憑證移除 | `grep -i emudhra <bundle>` | ✅ 無匹配（exit 1） |
| 6 | 系統 bundle 未改 | 檢查 `/etc/ssl/certs/ca-certificates.crt` | ✅ 保持原狀 |
| 7 | 4 個 checker host rejected | 未執行 | ⬜ 待補 |
| 8 | BEA mTLS baseline | 未執行 | ⬜ 待補 |
| 9 | 應用冒煙測試 | 未執行 | ⬜ 待補 |

---

## 4. 詳細測試紀錄

### 4.1 檔案與權限

```text
$ docker run --rm mmhk/php-docker:7.4-fpm-ca-fix ls -lh /usr/local/share/ca-certificates/cacert.pem
-rw-r--r-- 1 root root 196K Nov 11 15:01 /usr/local/share/ca-certificates/cacert.pem
```

### 4.2 PHP ini 設定

```text
$ docker run --rm mmhk/php-docker:7.4-fpm-ca-fix php -i | grep -E "openssl.cafile|curl.cainfo"
curl.cainfo    => /usr/local/share/ca-certificates/cacert.pem => /usr/local/share/ca-certificates/cacert.pem
openssl.cafile => /usr/local/share/ca-certificates/cacert.pem => /usr/local/share/ca-certificates/cacert.pem
```

### 4.3 SSL 連線

執行 `test-ssl.php`：

```text
=== SSL Connection Test ===

1. Testing cURL SSL connection...
   ✓ cURL SSL connection successful (HTTP 200)

2. Testing file_get_contents SSL connection...
   ✓ file_get_contents SSL connection successful

3. CA Bundle Information:
   CA File: /usr/local/share/ca-certificates/cacert.pem
   Size: 200,116 bytes
   Certificates: 118

=== Test Complete ===
```

### 4.4 bundle 內容

- 大小：200,116 bytes
- 憑證數：118
- `grep -i emudhra`：無輸出（exit code 1）

---

## 5. 與原計劃驗證項目的差異

`docs/plans/2026-11-09-emudhra-ca-bundle-fix.md` 原定驗證包含「4 個 checker host 全部 `errno=60`」與「BEA baseline `errno=56`、`verify=0`」等項目。本次僅完成通用 HTTPS 連線與 bundle 內容驗證，**上述針對性驗證與應用冒煙測試尚未執行**，因此尚不能宣稱已覆蓋所有依賴舊 root 的服務。

---

## 6. 結論

| 項目 | 結論 |
|---|---|
| bundle 下載與權限 | ✅ 正常 |
| PHP ini pin | ✅ 生效 |
| cURL / stream SSL | ✅ 正常 |
| eMudhra 憑證 | ✅ 已不在 bundle |
| 系統 CA 隔離 | ✅ 未受影響 |
| 針對性／應用驗證 | ⬜ 待補 |

初步驗證通過，修復可部署；但在完成第 3 節第 7–9 項前，仍應視為「部分驗證」。

---

## 附錄 A：重現指令

```bash
docker build -t mmhk/php-docker:7.4-fpm-ca-fix .

docker run --rm mmhk/php-docker:7.4-fpm-ca-fix ls -lh /usr/local/share/ca-certificates/cacert.pem
docker run --rm mmhk/php-docker:7.4-fpm-ca-fix php -i | grep -E "openssl.cafile|curl.cainfo"
docker run --rm -v "$PWD/tests/verify-ca-bundle.php:/verify.php:ro" mmhk/php-docker:7.4-fpm-ca-fix php /verify.php
docker run --rm -v "$PWD/test-ssl.php:/test-ssl.php:ro" mmhk/php-docker:7.4-fpm-ca-fix php /test-ssl.php
docker run --rm mmhk/php-docker:7.4-fpm-ca-fix grep -i emudhra /usr/local/share/ca-certificates/cacert.pem
```

## 附錄 B：參考資料

- eMudhra 事件：https://blog.cloudflare.com/emudhra-certificate-compromise
- curl CA extract：https://curl.se/docs/caextract.html
- CVE-2026-111943 / CVE-2026-111944
