#!/usr/bin/env bash

set -u

FRED_SECRET_FILE="/run/secrets/fred_key"

if [[ -f "$FRED_SECRET_FILE" ]]; then
    if ! FRED_KEY="$(cat "$FRED_SECRET_FILE")"; then
        printf 'ERROR: Unable to read Docker secret %s\n' "$FRED_SECRET_FILE" >&2
        exit 1
    fi

    if [[ -z "$FRED_KEY" ]]; then
        printf 'ERROR: Docker secret %s is empty\n' "$FRED_SECRET_FILE" >&2
        exit 1
    fi

    export FRED_KEY
elif [[ -z "${FRED_KEY:-}" ]]; then
    printf 'ERROR: FRED API key not provided. Supply Docker secret %s or FRED_KEY environment variable.\n' \
        "$FRED_SECRET_FILE" >&2
    exit 1
fi

exec "$@"
