#!/bin/sh
set -e

umask 0000

echo "running as:" && id

exec "$@"