#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ARTIFACT_ROOT="${SVRAAS_ARTIFACT_ROOT:-/artifacts}"
CHECK_INTERVAL="${SVRAAS_CHECK_INTERVAL:-60}"
RETRY_INTERVAL="${SVRAAS_RETRY_INTERVAL:-3600}"

FRED_SERIES_ID="UMCSENT"
FRED_SERIES_URL="https://api.stlouisfed.org/fred/series"

if ! [[ "$CHECK_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: SVRAAS_CHECK_INTERVAL must be a positive integer number of seconds.\n' >&2
    exit 1
fi

if ! [[ "$RETRY_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: SVRAAS_RETRY_INTERVAL must be a positive integer number of seconds.\n' >&2
    exit 1
fi

get_fred_latest_month() {
    local response
    local latest_month

    if ! response="$(
        printf '%s\n' \
            "url = \"${FRED_SERIES_URL}\"" \
            "get" \
            "silent" \
            "show-error" \
            "fail" \
            "data-urlencode = \"series_id=${FRED_SERIES_ID}\"" \
            "data-urlencode = \"api_key=${FRED_KEY}\"" \
            "data-urlencode = \"file_type=json\"" |
            curl --config -
    )"; then
        return 1
    fi

    if ! latest_month="$(
        printf '%s' "$response" |
            python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["seriess"][0]["observation_end"])
'
    )"; then
        return 1
    fi

    if ! [[ "$latest_month" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi

    printf '%s\n' "$latest_month"
}

get_latest_completed_month() {
    local artifacts=()
    local latest_artifact
    local latest_month

    shopt -s nullglob
    artifacts=( "${ARTIFACT_ROOT}"/lstm_*.json )
    shopt -u nullglob

    if (( ${#artifacts[@]} == 0 )); then
        return 1
    fi

    latest_artifact="$(
        printf '%s\n' "${artifacts[@]}" |
            sort |
            tail -n 1
    )"

    if ! latest_month="$(
        python3 -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as artifact:
    data = json.load(artifact)

print(data["metadata"]["latest_model_month"])
' "$latest_artifact"
    )"; then
        printf 'WARNING: Unable to read latest_model_month from %s\n' \
            "$latest_artifact" >&2
        return 1
    fi

    if ! [[ "$latest_month" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        printf 'WARNING: Invalid latest_model_month in %s\n' \
            "$latest_artifact" >&2
        return 1
    fi

    printf '%s\n' "$latest_month"
}

run_models() {
    local status

    printf 'New model data is available. Starting model suite.\n'

    "$SCRIPT_DIR/run_all.sh"
    status=$?

    if (( status != 0 )); then
        printf 'ERROR: Model suite failed with exit code %d.\n' \
            "$status" >&2
        return "$status"
    fi

    printf 'Model suite completed successfully.\n'
}

while true; do
    printf '\n=== SVR availability check: %s ===\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    sleep_interval="$CHECK_INTERVAL"

    if ! fred_month="$(get_fred_latest_month)"; then
        printf 'ERROR: Unable to determine latest UMCSENT month from FRED.\n' >&2
    elif artifact_month="$(get_latest_completed_month)"; then
        printf 'FRED latest month:      %s\n' "$fred_month"
        printf 'Latest completed month: %s\n' "$artifact_month"

        if [[ "$fred_month" > "$artifact_month" ]]; then
            if ! run_models; then
                sleep_interval="$RETRY_INTERVAL"
                printf 'Model suite will be retried after %s seconds.\n' \
                    "$sleep_interval" >&2
            fi
        elif [[ "$fred_month" == "$artifact_month" ]]; then
            printf 'Model artifacts are current. No run required.\n'
        else
            printf 'WARNING: Artifact month is newer than FRED. No run will be started.\n' >&2
        fi
    else
        printf 'No completed LSTM artifact found.\n'

        if ! run_models; then
            sleep_interval="$RETRY_INTERVAL"
            printf 'Model suite will be retried after %s seconds.\n' \
                "$sleep_interval" >&2
        fi
    fi

    printf 'Sleeping for %s seconds.\n' "$sleep_interval"
    sleep "$sleep_interval"
done
