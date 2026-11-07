#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

publish_stage() {
    local model="$1"

    # Reporting must never prevent a model from running.
    if ! python3 "$SCRIPT_DIR/status.py" \
        --root "${SVRAAS_ARTIFACT_ROOT:-/artifacts}" stage "$model"; then
        printf 'WARNING: Unable to report model stage %s.\n' "$model" >&2
    fi
}

run_model() {
    local name="$1"
    local script="$2"

    printf '\n=== Running %s ===\n' "$name"
    publish_stage "$name"

    Rscript "$script"
    local status=$?

    if (( status != 0 )); then
        printf '\nERROR: %s failed with exit code %d\n' "$name" "$status" >&2
        exit "$status"
    fi

    printf '=== Completed %s ===\n' "$name"
}

run_model "SVR-AR"    "${SCRIPT_DIR}/ar/SVR-AR.R"
run_model "SVR-ARIMA" "${SCRIPT_DIR}/arima/SVR-ARIMA.R"
run_model "SVR-MLP"   "${SCRIPT_DIR}/mlp/SVR-MLP.R"
run_model "SVR-LSTM"  "${SCRIPT_DIR}/lstm/SVR-LSTM.R"

printf '\n=== All SVR model runners completed successfully ===\n'
