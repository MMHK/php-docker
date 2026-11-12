#!/bin/sh
#
# Build PHP 7.4.33 from source with the CVE-2026-109618/109619 backport and
# embed the repository's extensions statically into php / php-fpm.
#
# Runs as root inside the builder stage. It intentionally DOWNLOADS, EXTRACTS,
# COMPILES and INSTALLS in one Docker RUN so source tarballs and build
# leftovers never become a separate image layer (the builder stage itself is
# not shipped; the runtime stage only copies /usr/local).
#
# The source tree is kept after the build so that
# docker-php-ext-static-install can add extensions later in the builder stage.

set -eu

PHP_INI_DIR="${PHP_INI_DIR:-/usr/local/etc/php}"
STATIC_CONF="${STATIC_CONF:-/usr/local/share/php-docker/static-extensions.conf}"
PHP_STATIC_EXTS="${PHP_STATIC_EXTS:-bcmath bz2 exif ffi gd gettext mysqli pdo_mysql soap sockets zip snmp shmop memcached imagick mcrypt redis timezonedb}"
PECL_SRC="${PECL_SRC:-/usr/src/pecl}"

log() {
	printf '>>> %s\n' "$*"
}

die() {
	printf '!!! %s\n' "$*" >&2
	exit 1
}

[ -f "$STATIC_CONF" ] || die "missing $STATIC_CONF"
[ -f /usr/src/php-cve.patch ] || die "missing /usr/src/php-cve.patch"

# ---------------------------------------------------------------------------
# download + verify PHP source and patch
# ---------------------------------------------------------------------------
log "downloading PHP ${PHP_VERSION}"
mkdir -p /usr/src
curl -fsSL -o /usr/src/php.tar.xz "$PHP_URL"
printf '%s *%s\n' "$PHP_SHA256" /usr/src/php.tar.xz | sha256sum -c -
printf '%s *%s\n' "$PHP_CVE_PATCH_SHA256" /usr/src/php-cve.patch | sha256sum -c -

# ---------------------------------------------------------------------------
# extract + apply the CVE backport patch
# ---------------------------------------------------------------------------
log "extracting PHP source and applying CVE patch"
docker-php-source extract
cd /usr/src/php
patch -p1 --fuzz=0 < /usr/src/php-cve.patch
touch /usr/src/php/.docker-cve-patched

# ---------------------------------------------------------------------------
# stage PECL sources inside ext/ so buildconf picks them up
# ---------------------------------------------------------------------------
log "staging PECL sources"
mkdir -p "$PECL_SRC"
while read -r name version sha256; do
	[ -n "$name" ] || continue
	tarball="$PECL_SRC/$name-$version.tgz"

	echo ">>> staging $name $version"
	curl --retry 5 --retry-delay 5 --retry-connrefused -fsSL \
		-o "$tarball" "https://pecl.php.net/get/$name-$version.tgz"
	printf '%s  %s\n' "$sha256" "$tarball" | sha256sum -c -
	mkdir -p "/usr/src/php/ext/$name"
	tar -xzf "$tarball" -C "/usr/src/php/ext/$name" --strip-components=1 "$name-$version"
	rm -f "$tarball"
done <<'PECL_PACKAGES'
memcached   3.4.0    c163434eb0da97c8f45c7ad41d979d381f8b81c49402b1b90b063987fb37972e
imagick     3.8.1    3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee
mcrypt      1.0.9    2a9ef0817d3bf677f6d7baf8e325629a2758974735d8abad6566384788d424a5
timezonedb  2026.5   affcad3175b7d2d3dde359ca2737addc8c8c95de355c2c73a2bab69bbbc2e012
redis       6.0.2    01aeccb0e14f897fe56f0509be6e6991ff0ad459f9d34e95e4556d02699b9a03
PECL_PACKAGES
rmdir "$PECL_SRC" 2>/dev/null || true

# ---------------------------------------------------------------------------
# save the base configure arguments + static extension manifest
# ---------------------------------------------------------------------------
gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"

BASE_ARGS_FILE=/usr/src/php/.docker-configure-base
MANIFEST=/usr/src/php/.docker-static-exts

cat > "$BASE_ARGS_FILE" <<EOF
--build=$gnuArch
--with-config-file-path=$PHP_INI_DIR
--with-config-file-scan-dir=$PHP_INI_DIR/conf.d
--enable-option-checking=fatal
--with-mhash
--with-pic
--enable-ftp
--enable-mbstring
--enable-mysqlnd
--with-password-argon2
--with-sodium=shared
--with-pdo-sqlite=/usr
--with-sqlite3=/usr
--with-curl
--with-iconv
--with-openssl
--with-readline
--with-zlib
--disable-phpdbg
--with-pear
--with-libdir=lib/$debMultiarch
--disable-cgi
--enable-fpm
--with-fpm-user=www-data
--with-fpm-group=www-data
--enable-opcache
EOF

for ext in $PHP_STATIC_EXTS; do
	printf '%s\n' "$ext" >> "$MANIFEST"
done

if [ "$gnuArch" = 's390x-linux-gnu' ]; then
	printf '%s\n' '--without-pcre-jit' >> "$BASE_ARGS_FILE"
fi

# https://bugs.php.net/bug.php?id=74125
if [ ! -d /usr/include/curl ]; then
	ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl
fi

# ---------------------------------------------------------------------------
# build configure flags from the shared extension table
# ---------------------------------------------------------------------------
EXT_FLAGS=
for ext in $PHP_STATIC_EXTS; do
	flags="$(awk -F '\t' -v want="$ext" '$1 == want { print $2 }' "$STATIC_CONF")"
	[ -n "$flags" ] || die "no configure flags for static extension: $ext"
	EXT_FLAGS="$EXT_FLAGS $flags"
done

log "running buildconf --force"
./buildconf --force

log "running configure"
set --
while IFS= read -r arg; do
	[ -n "$arg" ] && set -- "$@" "$arg"
done < "$BASE_ARGS_FILE"
for arg in $EXT_FLAGS; do
	set -- "$@" "$arg"
done

CFLAGS="${PHP_CFLAGS:-}" CPPFLAGS="${PHP_CPPFLAGS:-}" LDFLAGS="${PHP_LDFLAGS:-}" ./configure "$@"

log "compiling PHP + static extensions"
make -j "$(nproc)"
# Keep *.a in the build tree: the builder stage stays behind after this RUN
# and docker-php-ext-static-install needs the intermediates to relink
# opcache/sodium. Only the installed copies are removed from the runtime tree.
make install
find /usr/local/lib/php/extensions -type f -name '*.a' -delete

log "stripping binaries"
find /usr/local -type f -perm '/0111' -exec sh -euxc 'strip --strip-all "$@" || :' -- '{}' +

cp -v php.ini-* "$PHP_INI_DIR/"
cd /

# OPcache is forced shared by PHP 7.4; sodium is shared as in the official image.
docker-php-ext-enable opcache sodium

log "build finished"
php --version
php -m
