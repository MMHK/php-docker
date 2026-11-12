# syntax=docker/dockerfile:1
# Patched PHP 7.4 FPM image — CVE-2026-109618 / CVE-2026-109619
#
# Multi-stage:
#   base    : bullseye archive sources + no-debian-php pin, shared by both stages
#   builder : PHP 7.4.33 source + CVE backport + extensions statically linked
#   runtime : only runtime files and libraries; no compiler, no PHP source
#
# PHP 7.4 is EOL, so the official image no longer ships. The recipe mirrors
# docker-library/php 7.4/bullseye/fpm (docker-library/php@b9f1715).
#
# Integrity: the release tarball, the CVE patch and every PECL tarball are
# pinned by SHA256.

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

ENV PHP_VERSION 7.4.33
ENV PHP_URL="https://www.php.net/distributions/php-7.4.33.tar.xz"
ENV PHP_SHA256="924846abf93bc613815c55dd3f5809377813ac62a9ec4eb3778675b82a27b927"
ENV PHP_CVE_PATCH_SHA256="d059c1b4ea0f9023a1e1c17f6eddee82e3c2e029c60dd0a08fc5466764b5eaa4"

# vendored docker-php-* helpers + the static install/clean helpers
COPY docker-php-scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-*

COPY scripts/static-extensions.conf /usr/local/share/php-docker/static-extensions.conf
COPY --chmod=0755 scripts/build-php-static.sh /usr/local/bin/build-php-static.sh
COPY patches/php-7.4-CVE-2026-109618-109619.patch /usr/src/php-cve.patch

# pinned Composer (same version as the previous image)
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
	; \
	build-php-static.sh; \
	rm -rf /var/lib/apt/lists/*

# FPM base config (same as official image)
RUN set -eux; \
	cd /usr/local/etc; \
	if [ -d php-fpm.d ]; then \
		sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
		cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
	else \
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

# CA bundle: baked into /usr/local so the runtime stage can copy it verbatim.
# Debian bullseye is EOL and cannot receive ca-certificates updates via apt.
RUN set -eux; \
	mkdir -p /usr/local/share/ca-certificates; \
	curl -fsSL https://curl.se/ca/cacert.pem -o /usr/local/share/ca-certificates/cacert.pem; \
	chmod 644 /usr/local/share/ca-certificates/cacert.pem

# =============================================================================
# runtime: no compiler, no PHP source, no PECL staging
# =============================================================================
FROM base AS runtime

ENV TZ=Asia/Hong_Kong
ENV WWW_UID=1000
ENV WWW_GID=1000
ENV PHP_CVE_PATCHES="CVE-2026-109618,CVE-2026-109619"

RUN set -eux; \
	export DEBIAN_FRONTEND=noninteractive; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		xz-utils \
		tzdata \
		sudo \
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
		libstdc++6 \
		libgomp1 \
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

# copy only runtime payload from the builder
COPY --from=builder /usr/local/bin/php /usr/local/bin/php
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=builder /usr/local/lib/php /usr/local/lib/php
COPY --from=builder /usr/local/etc /usr/local/etc
COPY --from=builder /usr/local/share/ca-certificates /usr/local/share/ca-certificates

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

COPY file-upload.conf /usr/local/etc/php-fpm.d/file-upload.conf
COPY ca-bundle.ini /usr/local/etc/php/conf.d/ca-bundle.ini
COPY cve-2026-109618-109619.patched /usr/local/etc/php/cve-2026-109618-109619.patched
COPY cve-2026-109618-109619.ini /usr/local/etc/php/conf.d/zz-cve-2026-109618-109619.ini
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER www-data:www-data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
