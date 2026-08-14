#!/bin/sh
set -e

chown 65534:65534 /export/artifacts

exec "$@"
