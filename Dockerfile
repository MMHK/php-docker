# syntax=docker/dockerfile:1
# Patched PHP 8.0 FPM image — CVE-2026-109618 / CVE-2026-109619
#
# Multi-stage:
#   base    : bullseye archive sources + no-debian-php pin, shared by both stages
#   builder : PHP 8.0.30 source + CVE backport + extensions statically linked
#   runtime : only runtime files and libraries; no compiler, no PHP source
#
# Strategy: build the official PHP 8.0.30 release source (the exact tree used by
# php:8.0-fpm-bullseye) and apply the official backport patch from php-src branch
# "PHP-8.0-CVE-2026-109618-109619" (commit 82f8f31b). Keeping the release tree as
# the base makes the security changes explicit and reviewable; the patch lives in
# patches/php-8.0-CVE-2026-109618-109619.patch (verified to apply to 8.0.30 with
# zero fuzz and to reproduce the branch tree byte-for-byte for all touched files).
#
# The official image no longer ships for 8.0 (EOL), so the recipe below mirrors
# docker-library/php 8.0/bullseye/fpm (docker-library/php@41c9ad0) to keep the
# runtime behaviour identical to php:8.0-fpm-bullseye.
#
# Integrity: the release tarball is pinned by the official SHA256 (from
# docker-library/php), the patch by its own SHA256, and every PECL tarball by
# SHA256 (see scripts/build-php-static.sh). GitHub has no GPG .asc for the
# branch diff, so SHA256 replaces the upstream GPG check.
#
# Extensions: bundled and PECL extensions are compiled ONCE, statically into the
# php / php-fpm binaries (scripts/build-php-static.sh). Only OPcache is forced
# shared by PHP 8.0 itself, and sodium stays shared to match the official image.
# The builder stage is not shipped; use `--target builder` when you need
# docker-php-ext-static-install.

FROM debian:bullseye-slim AS base

# Debian bullseye is EOL: point apt at the frozen archive mirrors, otherwise
# deb.debian.org/debian-security returns 404 for bullseye packages (2026+).
RUN set -eux; \
	rm -f /etc/apt/sources.list.d/*.list; \
	{ \
		echo 'deb http://archive.debian.org/debian bullseye main'; \
		echo 'deb http://archive.debian.org/debian bullseye-updates main'; \
		echo 'deb http://archive.debian.org/debian-security bullseye-security main'; \
	} > /etc/apt/sources.list; \
# archive.debian.org Release files have expired Valid-Until timestamps
	echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# prevent Debian's PHP packages from being installed
# https://github.com/docker-library/php/pull/542
RUN set -eux; \
	{ \
		echo 'Package: php*'; \
		echo 'Pin: release *'; \
		echo 'Pin-Priority: -1'; \
	} > /etc/apt/preferences.d/no-debian-php

ENV PHP_INI_DIR /usr/local/etc/php
RUN set -eux; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
	[ ! -d /var/www/html ]; \
	mkdir -p /var/www/html; \
	chown www-data:www-data /var/www/html; \
	chmod 1777 /var/www/html

# =============================================================================
# builder: PHP source + CVE patch + static extensions
# =============================================================================
FROM base AS builder

# deps required for phpize / compiling extensions (build stage only)
ENV PHPIZE_DEPS \
		autoconf \
		dpkg-dev \
		file \
		g++ \
		gcc \
		libc-dev \
		make \
		pkg-config \
		re2c

# hardening flags (identical to the official image)
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -pie"

ENV PHP_VERSION 8.0.30
ENV PHP_URL="https://www.php.net/distributions/php-8.0.30.tar.xz"
ENV PHP_SHA256="216ab305737a5d392107112d618a755dc5df42058226f1670e9db90e77d777d9"
ENV PHP_CVE_PATCH_SHA256="4cda6e04266d0799c546cd0d79e1161eec82810da62252c164fc19ee00571b54"

# vendored docker-php-* helpers + the static install/clean helpers
COPY docker-php-scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-*

# extension name -> configure flags (shared by the build script and
# docker-php-ext-static-install)
COPY scripts/static-extensions.conf /usr/local/share/php-docker/static-extensions.conf
COPY --chmod=0755 scripts/build-php-static.sh /usr/local/bin/build-php-static.sh
COPY patches/php-8.0-CVE-2026-109618-109619.patch /usr/src/php-cve.patch

# pinned Composer (same version as the 7.4 branch)
ADD --chmod=0755 --checksum=sha256:dd158c0afd41d15fac89e1b4e47b5d42911fe316c3687cd5edac98319b25d028 \
	https://getcomposer.org/download/2.11.2/composer.phar \
	/usr/local/bin/composer

# build PHP, extensions and their system dependencies in one layer
RUN set -eux; \
	export DEBIAN_FRONTEND=noninteractive; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		$PHPIZE_DEPS \
		ca-certificates \
		curl \
		xz-utils \
		patch \
		libargon2-dev \
		libcurl4-openssl-dev \
		libonig-dev \
		libreadline-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libxml2-dev \
		zlib1g-dev \
		libbz2-dev \
		libffi-dev \
		libfreetype6-dev \
		libjpeg62-turbo-dev \
		libpng-dev \
		libwebp-dev \
		libxpm-dev \
		libzip-dev \
		libsnmp-dev \
		libmcrypt-dev \
		libmagickwand-dev \
		libmemcached-dev \
		libsasl2-dev \
		liblz4-dev \
		libzstd-dev \
		liblzf-dev \
		libgmp-dev \
		libpq-dev \
	; \
	build-php-static.sh; \
	rm -rf /var/lib/apt/lists/*

# FPM base config (same as official image)
RUN set -eux; \
	cd /usr/local/etc; \
	if [ -d php-fpm.d ]; then \
		# for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
		sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
		cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
	else \
		# PHP 5.x doesn't use "include=" by default, so we'll create our own simple config that mimics PHP 7+ for consistency
		mkdir php-fpm.d; \
		cp php-fpm.conf.default php-fpm.d/www.conf; \
		{ \
			echo '[global]'; \
			echo 'include=etc/php-fpm.d/*.conf'; \
		} | tee php-fpm.conf; \
	fi; \
	{ \
		echo '[global]'; \
		echo 'error_log = /proc/self/fd/2'; \
		echo; echo '; https://github.com/docker-library/php/pull/725#issuecomment-443540114'; echo 'log_limit = 8192'; \
		echo; \
		echo '[www]'; \
		echo '; php-fpm closes STDOUT on startup, so sending logs to /proc/self/fd/1 does not work.'; \
		echo '; https://bugs.php.net/bug.php?id=73886'; \
		echo 'access.log = /proc/self/fd/2'; \
		echo; \
		echo 'clear_env = no'; \
		echo; \
		echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
		echo 'catch_workers_output = yes'; \
		echo 'decorate_workers_output = no'; \
	} | tee php-fpm.d/docker.conf; \
	{ \
		echo '[global]'; \
		echo 'daemonize = no'; \
		echo; \
		echo '[www]'; \
		echo 'listen = 9000'; \
	} | tee php-fpm.d/zz-docker.conf; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
	{ \
		echo '; https://github.com/docker-library/php/issues/878#issuecomment-938595965'; \
		echo 'fastcgi.logging = Off'; \
	} > "$PHP_INI_DIR/conf.d/docker-fpm.ini"

# =============================================================================
# runtime: no compiler, no PHP source, no PECL staging
# =============================================================================
FROM base AS runtime

ENV TZ=Asia/Hong_Kong
ENV WWW_UID=1000
ENV WWW_GID=1000
# zz-cve-*.ini and the marker file are copied at the bottom; this mirror of the
# marker is visible in phpinfo() under Environment / $_SERVER / $_ENV.
ENV PHP_CVE_PATCHES="CVE-2026-109618,CVE-2026-109619"

# Runtime libraries only. Keep this list in sync with
# `ldd /usr/local/bin/php /usr/local/sbin/php-fpm` after a build; the CI/dev
# check is documented in docs/plans/php-8.0-static-extensions.md §10.2.
RUN set -eux; \
	export DEBIAN_FRONTEND=noninteractive; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		xz-utils \
		tzdata \
		unzip \
		\
		libargon2-1 \
		libreadline8 \
		libxml2 \
		libssl1.1 \
		libsqlite3-0 \
		zlib1g \
		libcurl4 \
		libonig5 \
		libsodium23 \
		\
		libbz2-1.0 \
		libffi7 \
		libfreetype6 \
		libjpeg62-turbo \
		libpng16-16 \
		libwebp6 \
		libwebpmux3 \
		libwebpdemux2 \
		libxpm4 \
		libx11-6 \
		libxext6 \
		libxau6 \
		libxdmcp6 \
		\
		libzip4 \
		libsnmp40 \
		libsnmp-base \
		libmcrypt4 \
		libmemcached11 \
		libmemcachedutil2 \
		libsasl2-2 \
		liblz4-1 \
		libzstd1 \
		liblzf1 \
		libstdc++6 \
		libgomp1 \
		\
		libgmp10 \
		libpq5 \
		\
		libmagickwand-6.q16-6 \
		libmagickcore-6.q16-6 \
		libmagickcore-6.q16-6-extra \
		imagemagick-6-common \
		ghostscript \
		fonts-urw-base35 \
		fontconfig \
	; \
	rm -rf /var/lib/apt/lists/*

# copy only the runtime payload from the builder
COPY --from=builder /usr/local/bin/php /usr/local/bin/php
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=builder /usr/local/lib/php /usr/local/lib/php
COPY --from=builder /usr/local/etc /usr/local/etc

# repo FPM tuning
RUN sed -i -e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php\.www\.log/php_admin_value[error_log]=\/proc\/self\/fd\/2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;chdir =/chdir =/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;rlimit_files = 1024/rlimit_files = 102400/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_children = 5/pm.max_children = 32/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.start_servers = 2/pm.start_servers = 6/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 10/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;pm.max_requests = 500/pm.max_requests = 5/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_flag\[log_errors\]/php_admin_flag\[log_errors\]/g" /usr/local/etc/php-fpm.d/*.conf \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data

STOPSIGNAL SIGQUIT

EXPOSE 9000

# CA bundle layer
# Debian bullseye 已 EOL，apt 的 ca-certificates 停在 eMudhra 事件前版本；
# 以 curl 官方固定日期 bundle 取代，供 PHP runtime 使用（不改系統 bundle）。
RUN set -eux; \
	mkdir -p /usr/local/share/ca-certificates; \
	curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
		-o /usr/local/share/ca-certificates/cacert-2026-11-05.pem \
		https://curl.se/ca/cacert-2026-11-05.pem; \
	echo "427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285 */usr/local/share/ca-certificates/cacert-2026-11-05.pem" \
		| sha256sum -c -; \
	chmod 0644 /usr/local/share/ca-certificates/cacert-2026-11-05.pem

COPY file-upload.conf /usr/local/etc/php-fpm.d/file-upload.conf
COPY opcache.ini /usr/local/etc/php/conf.d/opcache.ini
COPY ca-bundle.ini /usr/local/etc/php/conf.d/ca-bundle.ini
# backport proof for CVE-2026-109618 / CVE-2026-109619 (kept for traceability;
# 8.0 is EOL so the version number alone cannot prove the fixes are present)
COPY cve-2026-109618-109619.patched /usr/local/etc/php/cve-2026-109618-109619.patched
# same marker, but visible on phpinfo() under "Additional .ini files parsed"
COPY --chmod=0644 cve-2026-109618-109619.ini /usr/local/etc/php/conf.d/zz-cve-2026-109618-109619.ini
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER www-data:www-data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
