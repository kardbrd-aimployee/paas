"""Backup/restore failures must never be reported as successful operations."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("pg_isready", "pg_dump", "pg_dumpall", "aws", "psql", "sleep", "gzip", "openssl"):
            (self.bin / name).symlink_to(ROOT / "tests/fake_commands.py")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_ROOT": str(self.root),
            "S3_ACCESS_KEY_ID": "fake-key",
            "S3_SECRET_ACCESS_KEY": "fake-secret",
            "S3_BUCKET": "test-bucket",
            "S3_PREFIX": "backups",
            "S3_ENDPOINT": "",
            "POSTGRES_DATABASE": "example",
            "POSTGRES_BACKUP_ALL": "true",
            "POSTGRES_EXTRA_OPTS": "",
            "POSTGRES_WAIT_ATTEMPTS": "3",
            "POSTGRES_WAIT_INTERVAL": "0",
            "ENCRYPTION_PASSWORD": "",
            "DROP_PUBLIC": "no",
            "TMPDIR": str(self.root),
        }

    def run_script(self, script="do-backup.sh", **environment):
        return subprocess.run(["bash", str(ROOT / "backup" / script)], env={**self.env, **environment},
                              text=True, capture_output=True, timeout=15)

    def calls(self, name):
        path = self.root / "calls.jsonl"
        return [call for line in path.read_text().splitlines() if (call := json.loads(line))[0] == name] if path.exists() else []

    def objects(self):
        return [p for p in (self.root / "objects").rglob("*") if p.is_file()]

    def archive(self, data=b"SELECT 1;\n"):
        path = self.root / "example.sql.gz"
        path.write_bytes(gzip.compress(data))
        return str(path)

    def assert_no_upload(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.objects())
        self.assertNotIn("verified successfully", result.stdout)
        self.assertFalse(list(self.root.glob("postgres-backup.*")))

    def test_waits_for_postgres_before_dumping(self):
        result = self.run_script(FAKE_READY_AFTER="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("pg_isready")), 3)
        self.assertEqual(len(self.objects()), 1)

    def test_unavailable_postgres_cannot_upload(self):
        self.assert_no_upload(self.run_script(FAKE_READY_AFTER="99"))
        self.assertFalse(self.calls("pg_dumpall"))

    def test_partial_dump_failure_cannot_upload(self):
        self.assert_no_upload(self.run_script(FAKE_DUMP_FAIL="1"))

    def test_empty_successful_dump_cannot_upload(self):
        self.assert_no_upload(self.run_script(FAKE_SQL=""))

    def test_compression_and_encryption_failures_cannot_upload(self):
        for flag in ("FAKE_GZIP_FAIL", "FAKE_OPENSSL_FAIL"):
            with self.subTest(flag=flag):
                self.assert_no_upload(self.run_script(ENCRYPTION_PASSWORD="test-passphrase", **{flag: "1"}))

    def test_upload_failure_is_not_success(self):
        self.assert_no_upload(self.run_script(FAKE_UPLOAD_FAIL="1"))

    def test_wrong_remote_checksum_is_not_success(self):
        result = self.run_script(FAKE_HEAD_MISMATCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("verified successfully", result.stdout)

    def test_encrypted_archive_round_trip_and_password_stays_out_of_arguments(self):
        result = self.run_script(ENCRYPTION_PASSWORD="test-passphrase")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.objects()[0]
        result = self.run_script("restore.sh", RESTORE_FILE=str(archive), ENCRYPTION_PASSWORD="test-passphrase",
                                 BACKUP_SHA256=hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "restored.sql").read_text(), "CREATE TABLE example (id integer);\n")
        self.assertTrue(all("test-passphrase" not in call for call in self.calls("openssl")))
        self.assertIn("--set=ON_ERROR_STOP=1", self.calls("psql")[0])

    def test_remote_restore_selects_and_verifies_matching_archive(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script("restore.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "restored.sql").exists())

    def test_corrupt_or_empty_archive_never_touches_database(self):
        for contents in (b"not gzip", gzip.compress(b"")):
            with self.subTest(contents=contents):
                archive = Path(self.archive())
                archive.write_bytes(contents)
                result = self.run_script("restore.sh", RESTORE_FILE=str(archive), DROP_PUBLIC="yes",
                                         POSTGRES_BACKUP_ALL="false")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls("psql"))

    def test_bad_archive_checksum_never_touches_database(self):
        result = self.run_script("restore.sh", RESTORE_FILE=self.archive(), BACKUP_SHA256="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls("psql"))

    def test_sql_errors_are_not_reported_as_success(self):
        result = self.run_script("restore.sh", RESTORE_FILE=self.archive(), FAKE_SQL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Restore completed successfully", result.stdout)

    def test_schema_drop_targets_only_selected_database_after_archive_validation(self):
        result = self.run_script("restore.sh", RESTORE_FILE=self.archive(), POSTGRES_BACKUP_ALL="false", DROP_PUBLIC="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("psql")), 2)
        self.assertTrue(all("--dbname=example" in call for call in self.calls("psql")))

    def test_cluster_restore_rejects_single_schema_drop(self):
        result = self.run_script("restore.sh", RESTORE_FILE=self.archive(), DROP_PUBLIC="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls("psql"))

    def test_scheduler_retries_failures_instead_of_waiting_a_day(self):
        result = self.run_script("backup.sh", FAKE_DUMP_FAIL_ONCE="1", SCHEDULE="@daily",
                                 BACKUP_RETRY_INTERVAL="7", FAKE_STOP_AFTER_SLEEPS="2")
        self.assertEqual(result.returncode, 46)
        self.assertEqual(self.calls("sleep"), [["sleep", "7"], ["sleep", "86400"]])
        self.assertIn("Backup failed", result.stderr)
        self.assertIn("verified successfully", result.stdout)

    def test_manual_backup_propagates_failure_without_scheduling(self):
        result = self.run_script("backup.sh", SCHEDULE="**None**", FAKE_DUMP_FAIL="1")
        self.assertEqual(result.returncode, 42)
        self.assertFalse(self.calls("sleep"))

    def test_two_backups_preserve_both_objects(self):
        first = self.run_script()
        second = self.run_script()
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        self.assertEqual(len(self.objects()), 2)


if __name__ == "__main__":
    unittest.main()
