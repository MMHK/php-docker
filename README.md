# PHP Docker

[![dockeri.co](https://dockeri.co/image/mmhk/php-docker)](https://hub.docker.com/r/mmhk/php-docker)

![GitHub](https://img.shields.io/github/license/mmhk/mmfm)

適用於容器化的 PHP 執行環境，提供多個 PHP 版本的 FPM 映像，已內建常用擴展和最佳化配置。

## 專案簡介

本專案提供一系列基於官方 PHP 映像的 Docker 容器，針對生產環境進行了最佳化：

- **多版本支援**：PHP 5.6 到 8.4，滿足不同專案需求
- **預載擴展**：內建常用 PHP 擴展，減少建構時間
- **JIT 最佳化**：PHP 8.0+ 版本已啟用 OPcache JIT
- **生產就緒**：已調整 FPM 參數、日誌輸出、權限設定

## 主要分支與映像

| 分支 | PHP 版本 | Docker 映像 | 說明 |
|------|---------|------------|------|
| `5.6-fpm` | PHP 5.6 | `mmhk/php-docker:5.6-fpm` | 舊版專案支援 |
| `7.0-fpm` | PHP 7.0 | `mmhk/php-docker:7.0-fpm` | PHP 7.0 基礎版 |
| `7.0-cli` | PHP 7.0 | `mmhk/php-docker:7.0-cli` | CLI 版本 |
| `7.2-fpm` | PHP 7.2 | `mmhk/php-docker:7.2-fpm` | PHP 7.2 基礎版 |
| `7.2-fpm-nginx` | PHP 7.2 | `mmhk/php-docker:7.2-fpm-nginx` | 含 Nginx 整合 |
| `7.4-fpm` | PHP 7.4 | `mmhk/php-docker:7.4-fpm` | PHP 7.4 基礎版 |
| `7.4-fpm-pgsql` | PHP 7.4 | `mmhk/php-docker:7.4-fpm-pgsql` | 含 PostgreSQL 支援 |
| `8.0-fpm` | PHP 8.0 | `mmhk/php-docker:8.0-fpm` | PHP 8.0 + JIT |
| `8.1-fpm` | PHP 8.1 | `mmhk/php-docker:8.1-fpm` | PHP 8.1 + JIT |
| `8.2-fpm` | PHP 8.2 | `mmhk/php-docker:8.2-fpm` | PHP 8.2 + JIT |
| `8.3-fpm` | PHP 8.3 | `mmhk/php-docker:8.3-fpm` | PHP 8.3 + JIT |
| `8.4-fpm` | PHP 8.4 | `mmhk/php-docker:8.4-fpm` | PHP 8.4 + JIT |

### 特殊用途分支

| 分支 | 說明 |
|------|------|
| `caddy-2.8.4-aliyun` | Caddy 2.8.4 + 阿里雲整合 |
| `caddy-2.8.4-with-waf` | Caddy + WAF 防護 |
| `fpm-caddy-2.6.2` | FPM + Caddy 2.6.2 |
| `nginx-ws-fpm` | Nginx WebSocket + FPM |

## 已安裝擴展

所有 PHP 8.x 映像均包含以下擴展：

| 類別 | 擴展 |
|------|------|
| **資料庫** | mysqli, pdo_mysql, pdo_pgsql, pgsql, redis |
| **影像處理** | gd, imagick |
| **快取** | opcache (JIT), memcached |
| **加密** | gmp, mcrypt |
| **通訊協定** | soap, sockets, snmp |
| **檔案處理** | zip, bz2, exif |
| **數學運算** | bcmath |
| **其他** | composer, gettext, timezonedb, shmop, ffi, zstd |

## 快速開始

```bash
# 拉取映像
docker pull mmhk/php-docker:8.3-fpm

# 執行容器
docker run -d --name php-fpm \
  -p 9000:9000 \
  -v /path/to/your/app:/var/www/html \
  mmhk/php-docker:8.3-fpm
```

## OPcache / JIT 配置

PHP 8.0+ 映像已啟用 JIT tracing 模式：

```ini
[opcache]
opcache.enable=1
opcache.jit=tracing
opcache.jit_buffer_size=128M
```

如需自訂配置，請參考各分支的 README。

## 環境變數

| 變數 | 說明 | 預設值 |
|------|------|--------|
| `WWW_UID` | www-data 使用者 UID | 1000 |
| `WWW_GID` | www-data 群組 GID | 1000 |

## 相關連結

- [Docker Hub](https://hub.docker.com/r/mmhk/php-docker)
- [GitHub](https://github.com/MMHK/php-docker)
- [官方 PHP 映像](https://hub.docker.com/_/php)

## 授權

Apache License 2.0
