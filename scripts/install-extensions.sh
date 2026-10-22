#!/bin/sh
#
# Install the PHP extensions baked into mmhk/php-docker:7.4-fpm.
#
# Run inside the image as root during `docker build` (see Dockerfile). It is
# also safe to re-run in a container for debugging (see the note about the
# PEAR registry at the bottom of this header).
#
# Why PECL packages are installed from tarballs instead of by name
# ---------------------------------------------------------------
# pecl.php.net answers PEAR's REST metadata requests with a gzip-encoded body
# that PEAR does not decompress, so `pecl install <name>` fails with:
#
#     Package "<name>" Version "<version>" does not have REST xml available
#
# This affects every PECL extension (memcached, imagick, mcrypt, redis,
# timezonedb, ...) and is not retryable: the request succeeds, the payload is
# just unparseable. Retrying only wastes build time.
#
# Workaround: download each tarball ourselves, verify a pinned SHA256, and
# unpack it as
#
#     /usr/src/pecl/<name>/package.xml
#     /usr/src/pecl/<name>/<name>-<version>/...
#
# `install-php-extensions` accepts such a directory in place of a package name:
# it reads name/version from package.xml and runs `pecl install <dir>/package.xml`,
# which resolves everything locally and never touches the channel.
#
# Bumping a version: replace version + sha256 below. Grab the hash from
# https://pecl.php.net/get/<name>-<version>.tgz (sha256sum). Keep versions
# compatible with PHP 7.4 (check the <min>/<max> PHP entries in package.xml).
#
# Only PECL packages are listed here. Bundled extensions (gd, mysqli, opcache,
# soap, ...) and @composer are resolved by install-php-extensions as usual.

set -eu

PECL_SRC="${PECL_SRC:-/usr/src/pecl}"
PECL_BASE_URL="${PECL_BASE_URL:-https://pecl.php.net/get}"

# Number of install-php-extensions attempts. PECL REST failures are permanent,
# so this only covers transient network errors (composer download, apt mirrors).
IPE_ATTEMPTS="${IPE_ATTEMPTS:-2}"

fetch_pecl() {
	name="$1"
	version="$2"
	sha256="$3"
	tarball="$PECL_SRC/$name.tgz"
	dir="$PECL_SRC/$name"

	echo ">>> staging $name $version"
	curl --retry 5 --retry-delay 5 --retry-connrefused -fsSL \
		-o "$tarball" "$PECL_BASE_URL/$name-$version.tgz"
	echo "$sha256  $tarball" | sha256sum -c -
	mkdir -p "$dir"
	tar -xzf "$tarball" -C "$dir" --strip-components=1 "$name-$version"
	tar -xzf "$tarball" -C "$dir" package.xml
	rm -f "$tarball"
}

echo ">>> PHP extension build starting"
php --version

mkdir -p "$PECL_SRC"

# name        version   sha256
while read -r name version sha256; do
	[ -n "$name" ] || continue
	fetch_pecl "$name" "$version" "$sha256"
done <<'PECL_PACKAGES'
memcached   3.4.0    c163434eb0da97c8f45c7ad41d979d381f8b81c49402b1b90b063987fb37972e
imagick     3.8.1    3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee
mcrypt      1.0.9    2a9ef0817d3bf677f6d7baf8e325629a2758974735d8abad6566384788d424a5
timezonedb  2026.5   affcad3175b7d2d3dde359ca2737addc8c8c95de355c2c73a2bab69bbbc2e012
redis       6.0.2    01aeccb0e14f897fe56f0509be6e6991ff0ad459f9d34e95e4556d02699b9a03
PECL_PACKAGES

echo ">>> installing extensions"
attempt=1
while :; do
	if install-php-extensions \
		@composer \
		gd \
		"$PECL_SRC/memcached" \
		gettext \
		"$PECL_SRC/imagick" \
		"$PECL_SRC/mcrypt" \
		mysqli \
		"$PECL_SRC/redis" \
		pdo_mysql \
		opcache \
		exif \
		bcmath \
		soap \
		sockets \
		"$PECL_SRC/timezonedb" \
		zip \
		snmp \
		bz2 \
		shmop \
		ffi
	then
		break
	fi

	attempt=$((attempt + 1))
	if [ "$attempt" -gt "$IPE_ATTEMPTS" ]; then
		echo "!!! install-php-extensions failed after $IPE_ATTEMPTS attempt(s)" >&2
		exit 1
	fi
	echo "!!! install-php-extensions failed, retrying in 10s (attempt $attempt/$IPE_ATTEMPTS)"
	sleep 10
done

# keep the image small; sources are only needed while compiling
rm -rf "$PECL_SRC"

echo ">>> PHP extension build finished"
