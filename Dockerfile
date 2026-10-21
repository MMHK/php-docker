# Patched PHP 7.4 FPM image — CVE-2026-109618 / CVE-2026-109619
#
# Strategy: build the official PHP 7.4.33 release source (the exact tree used by
# php:7.4-fpm-bullseye) and apply the official backport patch from php-src branch
# "PHP-7.4-CVE-2026-109618-109619" (commit 712e60f9). Keeping the release tree as
# the base makes the security changes explicit and reviewable; the patch lives in
# patches/php-7.4-CVE-2026-109618-109619.patch (verified to apply to 7.4.33 with
# zero fuzz and to reproduce the branch tree byte-for-byte for all touched files).
#
# The patch is diffed against the PHP-7.4 branch tip (004cb827) rather than the
# PHP-7.4.33 tag: the two trees differ only in NEWS/configure.ac, and using the
# tag as base would rewrite configure.ac back to "7.4.31-dev".
#
# The official image no longer ships for 7.4 (EOL 2022-11), so the recipe below
# mirrors docker-library/php 7.4/bullseye/fpm (docker-library/php@b9f1715) to keep
# the runtime behaviour identical to php:7.4-fpm-bullseye.
#
# Integrity: the release tarball is pinned by the official SHA256 (from
# docker-library/php) and the patch by its own SHA256; GitHub has no GPG .asc
# for the branch diff, so SHA256 replaces the upstream GPG check.

FROM debian:bullseye-slim

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

# dependencies required for running "phpize" (kept at runtime, same as official)
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

# persistent / runtime deps
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		$PHPIZE_DEPS \
		ca-certificates \
		curl \
		xz-utils \
	; \
	rm -rf /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN set -eux; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
	[ ! -d /var/www/html ]; \
	mkdir -p /var/www/html; \
	chown www-data:www-data /var/www/html; \
	chmod 1777 /var/www/html

# hardening flags (identical to the official image)
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -pie"

# ---------------------------------------------------------------
# docker-php-* helper scripts (vendored from docker-library/php@b9f1715)
# needed by docker-php-source during the build and by install-php-extensions later
# ---------------------------------------------------------------
COPY docker-php-scripts/docker-php-source /usr/local/bin/
COPY docker-php-scripts/docker-php-ext-configure /usr/local/bin/
COPY docker-php-scripts/docker-php-ext-install /usr/local/bin/
COPY docker-php-scripts/docker-php-ext-enable /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-*

# ---------------------------------------------------------------
# official PHP 7.4.33 source + official CVE backport patch
# ---------------------------------------------------------------
ENV PHP_VERSION 7.4.33
ENV PHP_URL="https://www.php.net/distributions/php-7.4.33.tar.xz"
ENV PHP_SHA256="924846abf93bc613815c55dd3f5809377813ac62a9ec4eb3778675b82a27b927"
ENV PHP_CVE_PATCH_SHA256="d059c1b4ea0f9023a1e1c17f6eddee82e3c2e029c60dd0a08fc5466764b5eaa4"

COPY patches/php-7.4-CVE-2026-109618-109619.patch /usr/src/php-cve.patch

RUN set -eux; \
	mkdir -p /usr/src; \
	cd /usr/src; \
	curl -fsSL -o php.tar.xz "$PHP_URL"; \
	echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
	echo "$PHP_CVE_PATCH_SHA256 *php-cve.patch" | sha256sum -c -

# build & install PHP (official 7.4.33 release + CVE backport patch)
RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libargon2-dev \
		libcurl4-openssl-dev \
		libonig-dev \
		libreadline-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libxml2-dev \
		patch \
		zlib1g-dev \
	; \
	\
	export \
		CFLAGS="$PHP_CFLAGS" \
		CPPFLAGS="$PHP_CPPFLAGS" \
		LDFLAGS="$PHP_LDFLAGS" \
	; \
	docker-php-source extract; \
	cd /usr/src/php; \
# apply the official backport patch (no fuzz: it must match 7.4.33 exactly)
	patch -p1 --fuzz=0 < /usr/src/php-cve.patch; \
	rm -f /usr/src/php-cve.patch; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
# https://bugs.php.net/bug.php?id=74125
	if [ ! -d /usr/include/curl ]; then \
		ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
	fi; \
	./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		--enable-option-checking=fatal \
		--with-mhash \
		--with-pic \
		--enable-ftp \
		--enable-mbstring \
		--enable-mysqlnd \
		--with-password-argon2 \
		--with-sodium=shared \
		--with-pdo-sqlite=/usr \
		--with-sqlite3=/usr \
		--with-curl \
		--with-iconv \
		--with-openssl \
		--with-readline \
		--with-zlib \
		--disable-phpdbg \
# in PHP 7.4+, the pecl/pear installers are officially deprecated (requiring an explicit "--with-pear")
		--with-pear \
# bundled pcre does not support JIT on s390x
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		--with-libdir="lib/$debMultiarch" \
		--disable-cgi \
		--enable-fpm \
		--with-fpm-user=www-data \
		--with-fpm-group=www-data \
	; \
	make -j "$(nproc)"; \
	find -type f -name '*.a' -delete; \
	make install; \
	find \
		/usr/local \
		-type f \
		-perm '/0111' \
		-exec sh -euxc ' \
			strip --strip-all "$@" || : \
		' -- '{}' + \
	; \
	make clean; \
# keep the default example "php.ini" files somewhere easily discoverable
	cp -v php.ini-* "$PHP_INI_DIR/"; \
	cd /; \
	docker-php-source delete; \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
	find /usr/local -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*; \
# update pecl channel definitions https://github.com/docker-library/php/issues/443
	pecl update-channels; \
	rm -rf /tmp/pear ~/.pearrc; \
# smoke test
	php --version

# sodium was built as a shared module, so enable it (same as official image)
RUN docker-php-ext-enable sodium

# FPM base config (same as official image)
RUN set -eux; \
	cd /usr/local/etc; \
	if [ -d php-fpm.d ]; then \
		# for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
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

# ================= repo customisations =================

ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

ENV TZ=Asia/Hong_Kong
ENV WWW_UID=1000
ENV WWW_GID=1000

# redis PECL tarball, pinned. 6.0.2 supports PHP 7.4.
# Installed from a pre-extracted directory (see below) instead of the PECL
# channel because pecl.php.net now answers the PEAR REST metadata request with
# a gzip body that PEAR does not decompress ("Package redis does not have REST
# info xml available").
ENV REDIS_VERSION=6.0.2
ENV REDIS_URL="https://pecl.php.net/get/redis-6.0.2.tgz"
ENV REDIS_SHA256="01aeccb0e14f897fe56f0509be6e6991ff0ad459f9d34e95e4556d02699b9a03"

# base layer
# PECL/GitHub 拉取原始碼可能因網路不穩而失敗，install-php-extensions 本身無重試機制，
# 因此這裡在 shell 層面最多重試 5 次，每次失敗間隔 10 秒；5 次皆失敗則中止 build。
#
# redis 不走 PECL 通道：改為自行下載 tarball、解壓成「package.xml 與原始碼同層」，
# 再以目錄路徑交給 install-php-extensions（它會讀 package.xml 並執行 pecl install）。
RUN apt-get update && apt-get install -y tzdata sudo \
 && curl --retry 5 --retry-delay 5 -fsSL -o /usr/src/redis.tgz "$REDIS_URL" \
 && echo "$REDIS_SHA256 *redis.tgz" | (cd /usr/src && sha256sum -c -) \
 && mkdir -p /usr/src/redis \
 && tar -xzf /usr/src/redis.tgz -C /usr/src/redis --strip-components=1 "redis-$REDIS_VERSION" \
 && tar -xzf /usr/src/redis.tgz -C /usr/src/redis package.xml \
 && rm -f /usr/src/redis.tgz \
 && attempt=1 \
 && until install-php-extensions @composer gd memcached gettext imagick mcrypt mysqli /usr/src/redis pdo_mysql opcache exif bcmath soap sockets timezonedb zip snmp bz2 shmop ffi; do \
      attempt=$((attempt + 1)); \
      if [ "$attempt" -gt 5 ]; then \
        echo "install-php-extensions failed after 5 attempts" >&2; \
        exit 1; \
      fi; \
      echo "install-php-extensions failed, retrying in 10s (attempt $attempt/5)"; \
      sleep 10; \
    done \
 && rm -rf /var/lib/apt/lists/*

# config layer
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
# backport proof for CVE-2026-109618 / CVE-2026-109619 (required by the L0 gate;
# 7.4 is EOL so the version number alone cannot prove the fixes are present)
COPY cve-2026-109618-109619.patched /usr/local/etc/php/cve-2026-109618-109619.patched
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER www-data:www-data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
