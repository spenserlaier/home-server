"""Maintenance policy and interrupted-handoff checks; never contact a printer."""

import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "maintenance", Path(__file__).resolve().parents[1] / "modules/services/printer-maintenance.py"
)
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)
DAY = maintenance.DAY
NOW = 20000 * DAY


def completed(title="ordinary print", stamp=NOW - DAY):
    return {
        "job-id": 1,
        "job-name": title,
        "job-state": 9,
        "job-state-reasons": "completed-successfully",
        "job-impressions-completed": 1,
        "date-time-at-completed": dt.datetime.fromtimestamp(stamp, dt.timezone.utc).replace(tzinfo=None),
    }


class PolicyTests(unittest.TestCase):
    def test_recent_direct_airprint_postpones_idle_page(self):
        state = {"initialized": NOW - 10 * DAY}
        maintenance.observe(state, [completed()], NOW)
        self.assertIsNone(maintenance.due(state, NOW, 7, 14))

    def test_old_completed_job_can_trigger_on_first_check(self):
        state = {"initialized": NOW}
        maintenance.observe(state, [completed(stamp=NOW - 8 * DAY)], NOW)
        self.assertEqual(maintenance.due(state, NOW, 7, 14), "printer idle interval")

    def test_no_history_starts_with_grace_period(self):
        self.assertIsNone(maintenance.due({"initialized": NOW}, NOW, 7, 14))

    def test_history_expiration_does_not_erase_observed_completion(self):
        state = {"initialized": NOW - 10 * DAY, "last_success": NOW - DAY}
        maintenance.observe(state, [], NOW)
        self.assertIsNone(maintenance.due(state, NOW, 7, 14))

    def test_frequent_printing_still_has_color_exercise_deadline(self):
        state = {"initialized": NOW - 15 * DAY, "last_success": NOW - 60}
        self.assertEqual(maintenance.due(state, NOW, 7, 14), "maximum interval between dedicated color pages")

    def test_boundary_is_due_at_seven_days(self):
        state = {"initialized": NOW - 7 * DAY}
        self.assertIsNone(maintenance.due(state, NOW - 1, 7, 14))
        self.assertIsNotNone(maintenance.due(state, NOW, 7, 14))

    def test_failed_or_empty_jobs_do_not_reset_idle(self):
        for changes in ({"job-state": 8}, {"job-impressions-completed": 0}, {"job-state-reasons": "job-completed-with-errors"}):
            state = {"initialized": NOW - 8 * DAY}
            job = completed()
            job.update(changes)
            maintenance.observe(state, [job], NOW)
            self.assertNotIn("last_success", state)

    def test_uptime_fallback_and_bad_clock(self):
        self.assertEqual(maintenance.completion({"time-at-completed": 800, "job-printer-up-time": 1000}, NOW), NOW - 200)
        self.assertIsNone(maintenance.completion({"time-at-completed": 1001, "job-printer-up-time": 1000}, NOW))
        self.assertIsNone(maintenance.completion(completed(stamp=NOW + DAY), NOW))

    def test_pending_or_recent_attempt_blocks_another_submission(self):
        for field in ({"pending": {"title": "token"}}, {"last_attempt": NOW - 60}):
            state = {"initialized": NOW - 20 * DAY, **field}
            self.assertIsNone(maintenance.due(state, NOW, 7, 14))

    def test_printer_confirmation_recovers_lost_submission_response(self):
        state = {"pending": {"title": "token"}}
        maintenance.reconcile(state, [completed("token")], [], NOW)
        self.assertIsNone(state["pending"])
        self.assertEqual(state["last_maintenance"], NOW)

    def test_local_queue_recovers_pending_token_without_job_id(self):
        state = {"pending": {"title": "token"}}
        maintenance.reconcile(state, [], [{"job-name": "token", "job-state": 3}], NOW)
        self.assertIsNotNone(state["pending"])

    def test_unknown_or_only_cups_completed_handoff_requires_review(self):
        for local in ([], [{"job-name": "token", "job-state": 9}]):
            state = {"pending": {"title": "token"}}
            with self.assertRaises(RuntimeError):
                maintenance.reconcile(state, [], local, NOW)
            self.assertIsNotNone(state["pending"])

    def test_cancel_does_not_count_as_maintenance(self):
        state = {"pending": {"title": "token"}, "last_attempt": NOW}
        maintenance.reconcile(state, [], [{"job-name": "token", "job-state": 7}], NOW)
        self.assertIsNone(state["pending"])
        self.assertNotIn("last_maintenance", state)
        self.assertIsNone(maintenance.due({"initialized": NOW - 20 * DAY, **state}, NOW, 7, 14))


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.args = argparse.Namespace(
            state_directory=str(self.root), printer_uri="ipp://example/ipp/print",
            queue="Epson_ET_4950", idle_days=7, maximum_days=14, dry_run=False,
        )
        self.state = {"version": 1, "initialized": NOW - 8 * DAY}
        self.path = self.root / "state.json"
        self.path.write_text(json.dumps(self.state))
        self.printer = {"printer-state": 3, "printer-is-accepting-jobs": True, "queued-job-count": 0, "printer-state-reasons": "none"}

    def test_offline_printer_never_submits(self):
        with patch.object(maintenance, "jobs", side_effect=subprocess.TimeoutExpired("ipptool", 20)), patch.object(maintenance.subprocess, "run") as submit:
            maintenance.run(self.args)
            submit.assert_not_called()
        self.assertEqual(json.loads(self.path.read_text()), self.state)

    def test_busy_or_attention_state_defers(self):
        for change in ({"printer-state": 4}, {"queued-job-count": 1}, {"printer-is-accepting-jobs": False}, {"printer-state-reasons": "media-empty-error"}):
            with patch.object(maintenance.time, "time", return_value=NOW), patch.object(maintenance, "jobs", return_value=[]), patch.object(maintenance, "query", return_value=[{**self.printer, **change}]), patch.object(maintenance.subprocess, "run") as submit:
                maintenance.run(self.args)
                submit.assert_not_called()

    def test_existing_local_ordinary_job_defers(self):
        def get_jobs(uri, which):
            return [{"job-id": 2, "job-state": 3}] if "localhost" in uri else []
        with patch.object(maintenance.time, "time", return_value=NOW), patch.object(maintenance, "jobs", side_effect=get_jobs), patch.object(maintenance, "query", return_value=[self.printer]), patch.object(maintenance.subprocess, "run") as submit:
            maintenance.run(self.args)
            submit.assert_not_called()

    def test_dry_run_neither_writes_nor_submits(self):
        self.args.dry_run = True
        before = self.path.read_bytes()
        with patch.object(maintenance.time, "time", return_value=NOW), patch.object(maintenance, "jobs", return_value=[]), patch.object(maintenance, "query", return_value=[self.printer]), patch.object(maintenance.subprocess, "run") as submit:
            maintenance.run(self.args)
            submit.assert_not_called()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse((self.root / "exercise.pdf").exists())

    def test_lost_lp_response_keeps_durable_marker(self):
        def lose_response(*args, **kwargs):
            state = json.loads(self.path.read_text())
            self.assertTrue(state["pending"]["title"].startswith("homeserver-color-exercise-"))
            self.assertEqual(state["last_attempt"], NOW)
            raise subprocess.TimeoutExpired("lp", 30)
        with patch.object(maintenance.time, "time", return_value=NOW), patch.object(maintenance, "jobs", return_value=[]), patch.object(maintenance, "query", return_value=[self.printer]), patch.object(maintenance.subprocess, "run", side_effect=lose_response):
            with self.assertRaises(subprocess.TimeoutExpired):
                maintenance.run(self.args)
        self.assertIsNotNone(json.loads(self.path.read_text())["pending"])

    def test_one_submission_and_physical_confirmation(self):
        def get_jobs(uri, which):
            state = json.loads(self.path.read_text())
            pending = state.get("pending")
            return [completed(pending["title"], NOW)] if pending and "localhost" not in uri else []
        with patch.object(maintenance.time, "time", return_value=NOW), patch.object(maintenance.time, "sleep"), patch.object(maintenance, "jobs", side_effect=get_jobs), patch.object(maintenance, "query", return_value=[self.printer]), patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "request id is Epson_ET_4950-42 (1 file(s))")) as submit:
            maintenance.run(self.args)
            submit.assert_called_once()
            self.assertIn("print-color-mode=color", submit.call_args.args[0])
        state = json.loads(self.path.read_text())
        self.assertIsNone(state["pending"])
        self.assertEqual(state["last_maintenance"], NOW)

    def test_xml_response_preserves_job_groups_and_dates(self):
        groups = [{"attributes-charset": "utf-8"}, completed("first"), completed("second")]
        # The physical ET-4950 returns nameWithLanguage; CUPS may return a plain
        # nameWithoutLanguage string for the same attribute.
        groups[1]["job-name"] = {"language": "en-us", "string": "first"}
        xml = plistlib.dumps({"Successful": True, "Tests": [{"ResponseAttributes": groups}]})
        with patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, xml)):
            result = maintenance.jobs("ipp://example/ipp/print", "completed")
        self.assertEqual([job["job-name"] for job in result], ["first", "second"])
        self.assertEqual(maintenance.completion(result[0], NOW), NOW - DAY)


if __name__ == "__main__":
    unittest.main()
