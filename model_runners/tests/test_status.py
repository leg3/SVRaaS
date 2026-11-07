"""Unit tests for model_runners/status.py; no NFS or Docker required."""

from datetime import datetime, timezone
import importlib.util
import json
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

STATUS_SCRIPT = Path(__file__).resolve().parents[1] / "status.py"
spec = importlib.util.spec_from_file_location("svraas_runner_status", STATUS_SCRIPT)
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class StatusWriterTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name) / "artifacts"
        self.root.mkdir()
        self.lock = patch.object(status, "LOCK_PATH", Path(self.temp_dir.name) / "status.lock")
        self.lock.start()
        self.addCleanup(self.lock.stop)
        self.t = datetime(2026, 11, 7, 13, 0, tzinfo=timezone.utc)

    def read(self):
        return json.loads((self.root / "status.json").read_text(encoding="utf-8"))

    def test_begin_and_stage(self):
        status.record_event(self.root, "begin", now=self.t)
        started = self.read()
        self.assertEqual(started["state"], "building")
        self.assertEqual(stat.S_IMODE((self.root / "status.json").stat().st_mode), 0o644)
        self.assertIsNone(started["current_model"])
        self.assertEqual(started["started_at_utc"], "2026-11-07T13:00:00Z")
        status.record_event(self.root, "stage", model="SVR-ARIMA", now=self.t)
        staged = self.read()
        self.assertEqual(staged["current_model"], "SVR-ARIMA")
        self.assertEqual(staged["stage_started_at_utc"], "2026-11-07T13:00:00Z")

    def test_heartbeat_preserves_current_model_and_transition_time(self):
        status.record_event(self.root, "begin", now=self.t)
        status.record_event(self.root, "stage", model="SVR-LSTM", now=self.t)
        later = self.t.replace(minute=1)
        status.record_event(self.root, "beat", now=later)
        observed = self.read()
        self.assertEqual(observed["current_model"], "SVR-LSTM")
        self.assertEqual(observed["updated_at_utc"], "2026-11-07T13:00:00Z")
        self.assertEqual(observed["heartbeat_at_utc"], "2026-11-07T13:01:00Z")

    def test_no_heartbeat_record_before_initial_state(self):
        status.record_event(self.root, "beat", now=self.t)
        self.assertFalse((self.root / "status.json").exists())

    def test_known_model_failure_records_retry(self):
        status.record_event(self.root, "begin", now=self.t)
        status.record_event(self.root, "stage", model="SVR-MLP", now=self.t)
        status.record_event(self.root, "failed", exit_code=2, retry_seconds=3600, now=self.t)
        observed = self.read()
        self.assertEqual(observed["state"], "failed")
        self.assertEqual(observed["failed_model"], "SVR-MLP")
        self.assertEqual(observed["exit_code"], 2)
        self.assertEqual(observed["retry"]["next_attempt_at_utc"], "2026-11-07T14:00:00Z")

    def test_ready_after_build_clears_failure_related_fields(self):
        status.record_event(self.root, "begin", now=self.t)
        status.record_event(self.root, "stage", model="SVR-AR", now=self.t)
        status.record_event(self.root, "ready", now=self.t)
        observed = self.read()
        self.assertEqual(observed["state"], "ready")
        self.assertIsNone(observed["current_model"])
        self.assertEqual(observed["completed_at_utc"], "2026-11-07T13:00:00Z")
        self.assertNotIn("retry", observed)
        self.assertNotIn("failed_model", observed)

    def test_ready_for_preexisting_artifacts_does_not_invent_completion(self):
        status.record_event(self.root, "ready", now=self.t)
        self.assertNotIn("completed_at_utc", self.read())
        self.assertIsNone(self.read()["started_at_utc"])

    def test_invalid_transition_does_not_create_file(self):
        with self.assertRaises(ValueError):
            status.record_event(self.root, "stage", model="SVR-AR", now=self.t)
        self.assertFalse((self.root / "status.json").exists())

    def test_missing_artifact_root_is_not_created(self):
        with self.assertRaises(FileNotFoundError):
            status.record_event(self.root / "missing", "begin", now=self.t)
        self.assertFalse((self.root / "missing").exists())

    def test_atomic_write_failure_preserves_previous_json(self):
        status.record_event(self.root, "begin", now=self.t)
        original = (self.root / "status.json").read_bytes()
        with patch.object(status.os, "replace", side_effect=OSError("disk error")):
            with self.assertRaises(OSError):
                status.record_event(self.root, "stage", model="SVR-AR", now=self.t)
        self.assertEqual((self.root / "status.json").read_bytes(), original)
        self.assertEqual(list(self.root.glob(".status-*.tmp")), [])

    def test_command_line_smoke(self):
        # Each CLI command gets its own short-lived process.
        subprocess.run([sys.executable, str(STATUS_SCRIPT), "--root", str(self.root), "begin"], check=True)
        subprocess.run([sys.executable, str(STATUS_SCRIPT), "--root", str(self.root), "stage", "SVR-AR"], check=True)
        self.assertEqual(self.read()["current_model"], "SVR-AR")


if __name__ == "__main__":
    unittest.main()
