#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

run_model() {
    local name="$1"
    local script="$2"

    printf '\n=== Running %s ===\n' "$name"

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
