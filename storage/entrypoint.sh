#!/bin/sh
set -e

# Artifacts are a rebuildable cache. Start every storage instance clean.
rm -rf \
    /export/artifacts/* \
    /export/artifacts/.[!.]* \
    /export/artifacts/..?*

chown 65534:65534 /export/artifacts
chmod 0755 /export/artifacts

exec "$@"
