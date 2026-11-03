import importlib.util
import io
import json
import os
import sys
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("refresh_deploy", ROOT / "refresh-deploy.py")
refresh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(refresh)


class DeploymentRefreshTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / ".env").write_text("SECRET=keep-me\n")
        (self.root / "backups").mkdir()
        (self.root / "backups/data.tar.gz").write_bytes(b"database backup")
        (self.root / ".last-good.env").write_text("image=old\n")
        (self.root / "compose.yaml").write_bytes(b"old compose")
        (self.root / "Caddyfile").write_bytes(b"old proxy")
        self.files = {"compose.yaml": (b"new compose", 0o644), "Caddyfile": (b"new proxy", 0o644), "new.sh": (b"#!/bin/sh\n", 0o755)}
        self.baseline = {"compose.yaml": refresh.digest(b"old compose"), "Caddyfile": refresh.digest(b"old proxy")}

    def apply(self, **kwargs):
        return refresh.apply_release(self.root, "v2.7.0", "a" * 40, self.files, self.baseline, **kwargs)

    def test_refresh_preserves_secrets_data_and_application_rollback(self):
        backup = self.apply()
        self.assertEqual((self.root / "compose.yaml").read_bytes(), b"new compose")
        self.assertEqual((self.root / ".env").read_text(), "SECRET=keep-me\n")
        self.assertEqual((self.root / "backups/data.tar.gz").read_bytes(), b"database backup")
        self.assertEqual((self.root / ".last-good.env").read_text(), "image=old\n")
        self.assertEqual((backup / "files/compose.yaml").read_bytes(), b"old compose")
        self.assertEqual(json.loads((self.root / refresh.STATE).read_text())["commit"], "a" * 40)

    def test_local_edits_abort_before_any_file_is_changed(self):
        (self.root / "Caddyfile").write_bytes(b"custom proxy")
        with self.assertRaisesRegex(ValueError, "Local deployment changes"):
            self.apply()
        self.assertEqual((self.root / "compose.yaml").read_bytes(), b"old compose")
        self.assertFalse((self.root / refresh.HISTORY).exists())

    def test_deleted_managed_file_is_a_local_change(self):
        (self.root / "Caddyfile").unlink()
        with self.assertRaisesRegex(ValueError, "Caddyfile"):
            self.apply()

    def test_new_file_collision_is_not_silently_replaced(self):
        (self.root / "new.sh").write_bytes(b"operator script")
        with self.assertRaisesRegex(ValueError, "new.sh"):
            self.apply()

    def test_explicit_replacement_backs_up_custom_configuration(self):
        (self.root / "Caddyfile").write_bytes(b"custom proxy")
        backup = self.apply(replace_local=True)
        self.assertEqual((backup / "files/Caddyfile").read_bytes(), b"custom proxy")

    def test_restore_recovers_old_files_and_removes_new_files(self):
        backup = self.apply()
        refresh.restore(self.root, backup)
        self.assertEqual((self.root / "Caddyfile").read_bytes(), b"old proxy")
        self.assertFalse((self.root / "new.sh").exists())
        self.assertFalse((self.root / refresh.STATE).exists())
        self.assertEqual((self.root / ".env").read_text(), "SECRET=keep-me\n")

    def test_restore_refuses_post_upgrade_local_edits(self):
        backup = self.apply()
        (self.root / "new.sh").write_bytes(b"customized after upgrade")
        with self.assertRaisesRegex(ValueError, "changed since refresh"):
            refresh.restore(self.root, backup)
        self.assertEqual((self.root / "compose.yaml").read_bytes(), b"new compose")

    def test_corrupt_backup_does_not_partially_restore(self):
        backup = self.apply()
        (backup / "files/Caddyfile").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "Corrupt backup"):
            refresh.restore(self.root, backup)
        self.assertEqual((self.root / "compose.yaml").read_bytes(), b"new compose")

    def test_write_failure_restores_all_previously_written_files(self):
        original = refresh.atomic_write
        def fail_new_script(path, data, mode=0o600):
            if path == self.root / "new.sh":
                raise OSError("disk failure")
            return original(path, data, mode)
        with patch.object(refresh, "atomic_write", side_effect=fail_new_script):
            with self.assertRaisesRegex(OSError, "disk failure"):
                self.apply()
        self.assertEqual((self.root / "compose.yaml").read_bytes(), b"old compose")
        self.assertEqual((self.root / "Caddyfile").read_bytes(), b"old proxy")
        self.assertFalse((self.root / refresh.STATE).exists())

    def test_symlink_cannot_redirect_a_deployment_write(self):
        if os.name != "posix":
            self.skipTest("Symbolic links require privileges on Windows")
        external = self.root / "external"
        external.write_bytes(b"external data")
        (self.root / "Caddyfile").unlink()
        (self.root / "Caddyfile").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            self.apply(replace_local=True)
        self.assertEqual(external.read_bytes(), b"external data")

    def archive(self, extra=None):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name in refresh.REQUIRED:
                item = tarfile.TarInfo("voxhold/" + name)
                data = b"contents"
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
            if extra:
                archive.addfile(extra, io.BytesIO(b"x") if extra.isfile() else None)
        return output.getvalue()

    def test_archive_has_executable_shell_scripts(self):
        files = refresh.read_archive(self.archive())
        self.assertEqual(files["update.sh"][1] & 0o111, 0o111)

    def test_unsafe_archives_are_rejected_before_writing(self):
        for name in ["voxhold/../escape", "/absolute/path", "voxhold/.env", "other/compose.yaml", "voxhold/..\\escape", "voxhold/compose.yaml"]:
            with self.subTest(name=name):
                item = tarfile.TarInfo(name)
                item.size = 1
                with self.assertRaises(ValueError):
                    refresh.read_archive(self.archive(item))
        item = tarfile.TarInfo("voxhold/link")
        item.type = tarfile.SYMTYPE
        item.linkname = "/tmp/external"
        with self.assertRaises(ValueError):
            refresh.read_archive(self.archive(item))

    def test_repeat_refresh_uses_saved_baseline_and_does_not_make_backups(self):
        self.apply()
        count = len(list((self.root / refresh.HISTORY).iterdir()))
        state = refresh.load_state(self.root)
        self.assertIsNone(refresh.apply_release(self.root, "v2.7.0", "a" * 40, self.files, state["files"]))
        self.assertEqual(len(list((self.root / refresh.HISTORY).iterdir())), count)

    def test_legacy_cli_downloads_baseline_from_installed_version(self):
        (self.root / "VERSION").write_bytes(b"2.6.2\n")
        original = {"compose.yaml": (b"old compose", 0o644), "Caddyfile": (b"old proxy", 0o644), "VERSION": (b"2.6.2\n", 0o644)}
        target = dict(self.files, VERSION=(b"2.7.0\n", 0o644))
        with patch.object(sys, "argv", ["refresh-deploy.py", "--directory", str(self.root), "--ref", "main"]):
            with patch.object(refresh, "fetch_release", side_effect=[("b" * 40, original), ("a" * 40, target)]) as fetch:
                refresh.main()
        self.assertEqual([call.args[0] for call in fetch.call_args_list], ["v2.6.2", "main"])
        self.assertEqual((self.root / "VERSION").read_text(), "2.7.0\n")
        self.assertFalse((self.root / ".deploy-refresh.lock").exists())

    def test_concurrent_refresh_does_not_remove_other_process_lock(self):
        (self.root / ".deploy-refresh.lock").mkdir()
        with patch.object(sys, "argv", ["refresh-deploy.py", "--directory", str(self.root), "--ref", "main"]):
            with patch.object(refresh, "fetch_release") as fetch:
                with self.assertRaises(SystemExit):
                    refresh.main()
                fetch.assert_not_called()
        self.assertTrue((self.root / ".deploy-refresh.lock").is_dir())


if __name__ == "__main__":
    unittest.main()
