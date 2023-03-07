#!/bin/sh
set -e

umask 0000

usermod -u $WWW_UID www-data
groupmod -g $WWW_GID www-data

echo "running as:" && id

exec "$@"