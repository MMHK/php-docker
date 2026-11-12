# syntax=docker/dockerfile:1
#
# PHP 7.4 FPM + pgsql / pdo_pgsql
#
# 基礎映像 mmhk/php-docker:7.4-fpm 是「靜態擴充」建置：擴充在 builder stage 直接
# 編進 php / php-fpm，最終映像刻意不保留編譯器、PHP 源碼與 PEAR/PECL，
# 也沒有 install-php-extensions，因此不能在最終映像裡直接跑
# `RUN install-php-extensions ...`（會是 exit 127 / command not found）。
#
# 改用 multi-stage：
#   ext-builder : 以官方 php:7.4.33 映像提供 phpize / php-config / headers / 源碼，
#                 用 install-php-extensions 把 pgsql、pdo_pgsql 編成 .so
#   runtime     : 只取回 .so、對應 ini，以及執行期依賴 libpq5
#
# 兩個 stage 都是 PHP 7.4.33 NTS（extension API 20190902），ABI 一致；
# php 二進位有 export 符號，靜態建置的 php 仍可載入這兩個 .so。

FROM php:7.4.33-fpm-bullseye AS ext-builder

# 固定安裝器版本與 checksum，避免 releases/latest 無聲改版
ARG INSTALL_PHP_EXTENSIONS_VERSION=2.12.3
ADD --chmod=0755 \
	--checksum=sha256:9c26dd516b8147235c4e924c52e2f076fb2b3f278f5457e88918518ebfee9e01 \
	https://github.com/mlocati/docker-php-extension-installer/releases/download/${INSTALL_PHP_EXTENSIONS_VERSION}/install-php-extensions \
	/usr/local/bin/install-php-extensions

# pdo 是 PHP 核心內建模組（基礎映像已內建），不需要另外安裝
RUN install-php-extensions pgsql pdo_pgsql

FROM mmhk/php-docker:7.4-fpm

USER root

# libpq.so.5 是 pgsql / pdo_pgsql 的執行期依賴，基礎映像沒有帶
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends libpq5; \
	rm -rf /var/lib/apt/lists/*

# PHP 7.4 NTS 的 extension_dir；兩個 stage 版本相同，路徑固定
COPY --from=ext-builder \
	/usr/local/lib/php/extensions/no-debug-non-zts-20190902/pgsql.so \
	/usr/local/lib/php/extensions/no-debug-non-zts-20190902/pdo_pgsql.so \
	/usr/local/lib/php/extensions/no-debug-non-zts-20190902/

# 啟用擴充並在建置期驗證（載入失敗會讓 build 直接失敗）
RUN set -eux; \
	printf 'extension=pgsql.so\n' > /usr/local/etc/php/conf.d/docker-php-ext-pgsql.ini; \
	printf 'extension=pdo_pgsql.so\n' > /usr/local/etc/php/conf.d/docker-php-ext-pdo_pgsql.ini; \
	php -m | grep -qx pgsql; \
	php -m | grep -qx pdo_pgsql; \
	php -r 'exit(in_array("pgsql", PDO::getAvailableDrivers(), true) ? 0 : 1);'

USER www-data:www-data

EXPOSE 9000

CMD ["php-fpm"]
