#!/usr/bin/env python3
"""Publish runner state to the shared artifact directory.

Only the runner writes this file. The API will interpret freshness separately.
Commands make one atomic change; run_forever.sh will schedule periodic `beat`
commands in the next implementation step.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile

STATUS_NAME = "status.json"
LOCK_PATH = Path("/tmp/svraas-model-status.lock")
MODELS = ("SVR-AR", "SVR-ARIMA", "SVR-MLP", "SVR-LSTM")


def utc_now():
    return datetime.now(timezone.utc)


def iso_utc(instant):
    return instant.isoformat(timespec="seconds").replace("+00:00", "Z")


@contextmanager
def exclusive_writer():
    # The runner is single-replica. Lock only its local processes; no NFS lock
    # is needed between the heartbeat and the model-state transitions.
    with LOCK_PATH.open("a+") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def read_status(path):
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as source:
        result = json.load(source)
    if not isinstance(result, dict):
        raise ValueError("status.json must contain a JSON object")
    return result


def write_atomic(path, status):
    # The temporary file must be on the same filesystem for atomic replace.
    fd, temp_name = tempfile.mkstemp(prefix=".status-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            # API may read the file under a different NFS-mapped identity.
            os.fchmod(target.fileno(), 0o644)
            json.dump(status, target, sort_keys=True, indent=2)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def record_event(root, event, *, model=None, exit_code=None, retry_seconds=None, now=None):
    """Perform one serialized update. `beat` never invents a state."""
    now = now or utc_now()
    stamp = iso_utc(now)
    path = Path(root) / STATUS_NAME

    # Fail rather than creating a local /artifacts directory if NFS is absent.
    if not path.parent.is_dir():
        raise FileNotFoundError(f"artifact root unavailable: {path.parent}")

    with exclusive_writer():
        previous = read_status(path)

        if event == "begin":
            status = {
                "state": "building",
                "current_model": None,
                "started_at_utc": stamp,
                "stage_started_at_utc": None,
                "updated_at_utc": stamp,
                "heartbeat_at_utc": stamp,
            }
        elif event == "beat":
            if previous is None:
                # Before initial artifact inspection, the API should see
                # unknown, not an invented 'building' or 'ready' state.
                return
            status = previous
            status["heartbeat_at_utc"] = stamp
        elif event == "stage":
            if previous is None or previous.get("state") != "building":
                raise ValueError("cannot set model stage without an active build")
            if model not in MODELS:
                raise ValueError(f"unknown model stage: {model}")
            status = previous
            status.update(
                current_model=model,
                stage_started_at_utc=stamp,
                updated_at_utc=stamp,
                heartbeat_at_utc=stamp,
            )
        elif event == "ready":
            status = {
                "state": "ready",
                "current_model": None,
                "started_at_utc": previous.get("started_at_utc") if previous else None,
                "stage_started_at_utc": None,
                "updated_at_utc": stamp,
                "heartbeat_at_utc": stamp,
            }
            if previous and previous.get("state") == "building":
                status["completed_at_utc"] = stamp
            elif previous and previous.get("completed_at_utc"):
                status["completed_at_utc"] = previous["completed_at_utc"]
        elif event == "failed":
            if previous is None or previous.get("state") != "building":
                raise ValueError("cannot report a model failure without an active build")
            if exit_code is None or retry_seconds is None or retry_seconds <= 0:
                raise ValueError("failure requires an exit code and positive retry interval")
            status = {
                "state": "failed",
                "current_model": None,
                "failed_model": previous.get("current_model"),
                "error_code": "model_execution_failed",
                "exit_code": exit_code,
                "message": "Model execution failed; automatic retry scheduled.",
                "retry": {
                    "scheduled": True,
                    "next_attempt_at_utc": iso_utc(now + timedelta(seconds=retry_seconds)),
                },
                "started_at_utc": previous.get("started_at_utc"),
                "stage_started_at_utc": previous.get("stage_started_at_utc"),
                "updated_at_utc": stamp,
                "heartbeat_at_utc": stamp,
            }
        else:
            raise ValueError(f"unrecognized status event: {event}")

        write_atomic(path, status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("SVRAAS_ARTIFACT_ROOT", "/artifacts"))
    sub = parser.add_subparsers(dest="event", required=True)
    sub.add_parser("begin")
    stage = sub.add_parser("stage")
    stage.add_argument("model", choices=MODELS)
    sub.add_parser("ready")
    failed = sub.add_parser("failed")
    failed.add_argument("--exit-code", type=int, required=True)
    failed.add_argument("--retry-seconds", type=int, required=True)
    sub.add_parser("beat")
    args = parser.parse_args()
    record_event(
        args.root,
        args.event,
        model=getattr(args, "model", None),
        exit_code=getattr(args, "exit_code", None),
        retry_seconds=getattr(args, "retry_seconds", None),
    )


if __name__ == "__main__":
    main()
