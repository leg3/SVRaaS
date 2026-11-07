"""Integration tests for the Bash runner with fake curl/Rscript (no FRED or R)."""

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

RUNNER_DIR = Path(__file__).resolve().parents[1]


class RunnerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.model_log = self.root / "models.log"
        self.make_executable(
            "curl",
            '#!/usr/bin/env bash\n'
            'if [[ "${FAKE_FRED_UNAVAILABLE:-}" == "yes" ]]; then exit 22; fi\n'
            'printf \'{"seriess":[{"observation_end":"2026-07-01"}]}\\n\'\n',
        )
        self.make_executable(
            "Rscript",
            '#!/usr/bin/env bash\n'
            'model="$(basename "$1" .R)"\n'
            'echo "$model" >> "$MODEL_TEST_LOG"\n'
            'sleep "${FAKE_MODEL_SECONDS:-0}"\n'
            'if [[ "$model" == "${FAKE_FAIL_MODEL:-}" ]]; then exit 9; fi\n',
        )
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(self.bin_dir) + os.pathsep + self.env.get("PATH", ""),
            SVRAAS_ARTIFACT_ROOT=str(self.artifacts),
            SVRAAS_CHECK_INTERVAL="1",
            SVRAAS_RETRY_INTERVAL="5",
            SVRAAS_STATUS_HEARTBEAT_INTERVAL="1",
            FRED_KEY="fake-test-key",
            MODEL_TEST_LOG=str(self.model_log),
            FAKE_MODEL_SECONDS="0",
        )
        self.process = None
        self.addCleanup(self.stop_process)

    def make_executable(self, name, contents):
        path = self.bin_dir / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def read_status(self):
        try:
            return json.loads((self.artifacts / "status.json").read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None

    def wait_for(self, pred, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = pred()
            if result:
                return result
            if self.process and self.process.poll() is not None:
                self.fail(f"runner terminated unexpectedly: exit={self.process.returncode}")
            time.sleep(0.05)
        self.fail("timed out waiting for expected runner status")

    def start(self):
        output = (self.root / "runner.log").open("w", encoding="utf-8")
        self.addCleanup(output.close)
        self.process = subprocess.Popen(
            ["bash", str(RUNNER_DIR / "run_forever.sh")],
            env=self.env,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    def stop_process(self):
        if self.process:
            # The fixture owns a separate process group, including its fake
            # model and heartbeat. Stop all of them even during a long model.
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=2)

    def test_normal_build_records_stages_and_ready(self):
        self.env["FAKE_MODEL_SECONDS"] = "0.3"
        self.start()
        ready = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("state") == "ready" else None))
        self.assertIsNotNone(ready.get("completed_at_utc"))
        self.assertEqual(
            self.model_log.read_text(encoding="utf-8").splitlines(),
            ["SVR-AR", "SVR-ARIMA", "SVR-MLP", "SVR-LSTM"],
        )

    def test_heartbeat_continues_during_long_running_model(self):
        self.env["FAKE_MODEL_SECONDS"] = "5"
        self.start()
        building = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("current_model") == "SVR-AR" else None))
        before = building["heartbeat_at_utc"]
        updated = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("heartbeat_at_utc") != before else None), timeout=5)
        self.assertEqual(updated["state"], "building")
        self.assertEqual(updated["current_model"], "SVR-AR")
        self.assertEqual(updated["updated_at_utc"], building["updated_at_utc"])

    def test_failure_records_retry_and_heartbeat_continues(self):
        self.env.update(FAKE_FAIL_MODEL="SVR-ARIMA", FAKE_MODEL_SECONDS="0.2")
        self.start()
        failed = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("state") == "failed" else None))
        self.assertEqual(failed["failed_model"], "SVR-ARIMA")
        self.assertEqual(failed["exit_code"], 9)
        self.assertTrue(failed["retry"]["scheduled"])
        first_heartbeat = failed["heartbeat_at_utc"]
        subsequent = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("heartbeat_at_utc") != first_heartbeat else None), timeout=4)
        self.assertEqual(subsequent["state"], "failed")

    def test_new_runner_does_not_revive_old_build_when_fred_unavailable(self):
        old = {
            "state": "building", "current_model": "SVR-LSTM",
            "heartbeat_at_utc": "2026-01-01T00:00:00Z",
            "updated_at_utc": "2026-01-01T00:00:00Z",
        }
        (self.artifacts / "status.json").write_text(json.dumps(old), encoding="utf-8")
        self.env["FAKE_FRED_UNAVAILABLE"] = "yes"
        self.start()
        time.sleep(2.2)
        self.assertEqual(self.read_status(), old)
        self.assertIsNone(self.process.poll())

    def test_preexisting_current_cohort_marks_ready_without_model_run(self):
        (self.artifacts / "lstm_2026-07-01.json").write_text(
            json.dumps({"metadata": {"latest_model_month": "2026-07-01"}}),
            encoding="utf-8",
        )
        self.start()
        ready = self.wait_for(lambda: (s if (s := self.read_status()) and s.get("state") == "ready" else None))
        self.assertIsNone(ready.get("completed_at_utc"))
        self.assertFalse(self.model_log.exists())


if __name__ == "__main__":
    unittest.main()
