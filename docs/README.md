# 文件導覽（PHP 8.0 FPM 映像）

本目錄只放「設計 / 決策 / 驗證」文件；操作說明請看根目錄 `README.md`，
維護者注意事項請看 `AGENTS.md`。

## 現行文件（`docs/plans/`）

| 文件 | 主題 | 狀態 |
|---|---|---|
| [`php-8.0-cve-2026-109618-109619-patch.md`](plans/php-8.0-cve-2026-109618-109619-patch.md) | 從 8.0.30 原始碼編譯並套用 CVE backport 補丁 | ✅ 現行 |
| [`php-8.0-ca-bundle-fix.md`](plans/php-8.0-ca-bundle-fix.md) | 以固定日期 CA bundle 取代 EOL 的系統憑證 | ✅ 現行 |
| [`php-8.0-static-extensions.md`](plans/php-8.0-static-extensions.md) | 擴充靜態內嵌 + 三階段建置（本專案目前的擴充編譯方式） | ✅ 現行 |

## 歷史文件（`docs/archive/`）

| 文件 | 主題 | 狀態 |
|---|---|---|
| [`php-8.0-extension-install.md`](archive/php-8.0-extension-install.md) | 以 `install-php-extensions` 安裝 PECL `.so` | ⛔ 已廢止（由靜態內嵌取代） |

## 建議閱讀順序

1. `README.md` — 映像用途、已安裝擴充、執行方式
2. `docs/plans/php-8.0-static-extensions.md` — 目前如何編譯 PHP 與擴充
3. `docs/plans/php-8.0-cve-2026-109618-109619-patch.md` — CVE 補丁來源與驗證
4. `docs/plans/php-8.0-ca-bundle-fix.md` — CA bundle 的來源與 pin 方式
5. `scripts/README.md` — 建置腳本與「新增/升級擴充」流程

## 撰寫與歸檔規則

- 新計畫放 `docs/plans/`，檔名用 `php-8.0-<主題>.md`。
- 文件開頭保留「分支 / 目標鏡像 / 狀態 / 相關」區塊。
- 被取代的計畫搬到 `docs/archive/`，並在標題下加
  `⛔ 此文件已被 <新文件> 取代，僅保留作為歷史紀錄`。
- 實作完成後在文件中回填「實測結果」，不要只留計畫內容。
