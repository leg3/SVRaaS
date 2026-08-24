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
    local latest_month
    local status

    latest_month="$(
        python3 - "$ARTIFACT_ROOT" <<'PY'
import json
import os
import re
import sys

artifact_root = sys.argv[1]
max_attempts = 3

for attempt in range(1, max_attempts + 1):
    try:
        entries = os.listdir(artifact_root)

        artifacts = sorted(
            name
            for name in entries
            if name.startswith("lstm_") and name.endswith(".json")
        )

        if not artifacts:
            sys.exit(2)

        latest_artifact = os.path.join(
            artifact_root,
            artifacts[-1],
        )

        with open(
            latest_artifact,
            "r",
            encoding="utf-8",
        ) as artifact:
            data = json.load(artifact)

        latest_month = data["metadata"]["latest_model_month"]

        if not isinstance(latest_month, str) or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}",
            latest_month,
        ):
            raise ValueError(
                f"invalid latest_model_month in {latest_artifact}"
            )

    except (
        OSError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as exc:
        print(
            f"WARNING: Artifact read attempt "
            f"{attempt}/{max_attempts} failed: {exc}",
            file=sys.stderr,
        )

        if attempt == max_attempts:
            sys.exit(3)

        continue

    print(latest_month)
    sys.exit(0)

sys.exit(3)
PY
    )"
    status=$?

    case "$status" in
        0)
            printf '%s\n' "$latest_month"
            return 0
            ;;
        2)
            return 2
            ;;
        *)
            return 3
            ;;
    esac
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
    else
        artifact_month="$(get_latest_completed_month)"
        artifact_status=$?

        case "$artifact_status" in
            0)
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
                ;;

            2)
                printf 'No completed LSTM artifact found.\n'

                if ! run_models; then
                    sleep_interval="$RETRY_INTERVAL"
                    printf 'Model suite will be retried after %s seconds.\n' \
                        "$sleep_interval" >&2
                fi
                ;;

            *)
                printf 'ERROR: Artifact storage could not be read reliably after 3 attempts. No model run will be started.\n' >&2
                ;;
        esac
    fi

    printf 'Sleeping for %s seconds.\n' "$sleep_interval"
    sleep "$sleep_interval"
done
