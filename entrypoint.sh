#!/bin/sh
set -e

usermod -u $WWW_UID www-data
groupmod -g $WWW_GID www-data

umask 0000

echo "running as:" && id

exec "$@"