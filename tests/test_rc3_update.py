"""RC3 cumulative manifest anchors and audit self-integrity regressions."""
# SPDX-License-Identifier: AGPL-3.0-only
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
update = load("rc3_update", ROOT / "scripts/update-package.py")
audit = load("rc3_audit", ROOT / "scripts/audit-workspace.py")


class CompatibleAnchors(unittest.TestCase):
    def test_three_exact_versions_and_current_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / "source"; target.mkdir()
            item = {"path": "whatsapp.el", "before": hashlib.sha256(b"rc2").hexdigest(),
                    "compatible_before": [hashlib.sha256(b"rc1").hexdigest(), hashlib.sha256(b"3.1").hexdigest()],
                    "after": hashlib.sha256(b"rc3").hexdigest()}
            for contents in [b"rc2", b"rc1", b"3.1", b"rc3"]:
                (target / "whatsapp.el").write_bytes(contents)
                changes = update.preflight(target, root, {"files": [item]})
                self.assertEqual(len(changes), 0 if contents == b"rc3" else 1)
            (target / "whatsapp.el").write_bytes(b"unrecognized edits")
            with self.assertRaises(update.UpdateError):
                update.preflight(target, root, {"files": [item]})
            self.assertEqual((target / "whatsapp.el").read_bytes(), b"unrecognized edits")

    def test_bad_anchor_types_rejected(self):
        for anchors in ["0"*64, [123], ["fuzzy"], ["A"*64], ["0"*64]*4]:
            with self.subTest(anchors=anchors), self.assertRaises(update.UpdateError):
                update.compatible_baselines({"before": None, "compatible_before": anchors})

    def test_absent_file_requires_explicit_none_anchor(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory); (target / "whatsapp.el").write_text("fixture")
            item = {"path": "new.py", "before": "a"*64, "after": "b"*64}
            with self.assertRaises(update.UpdateError):
                update.preflight(target, target, {"files": [item]})
            item["compatible_before"] = [None]
            self.assertEqual(update.preflight(target, target, {"files": [item]}), [item])

    def test_old_single_before_anchor_remains_supported(self):
        self.assertEqual(update.compatible_baselines({"before": "a"*64}), {"a"*64})


class AuditIntegrity(unittest.TestCase):
    def run_fixture(self, mutate):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"; root.mkdir()
            source = root / "fixture.py"; source.write_text("before\n")
            output = Path(directory) / "audit"
            def run(*_args, **_kwargs):
                if mutate:
                    source.write_text("after\n")
                return {"exit_code": 0, "reason": None, "log_bytes": 0, "seconds": 0}
            with mock.patch.object(audit, "checks", return_value=[("fixture", ["fixture"])]), \
                 mock.patch.object(audit.shutil, "which", return_value="fixture"), \
                 mock.patch.object(audit, "run_gate", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                result = audit.run_audit(root, output)
            report = json.loads((output / "report.json").read_text())
            return result, report

    def test_source_mutation_overrides_successful_exit(self):
        result, report = self.run_fixture(True)
        self.assertFalse(result)
        self.assertEqual(report["checks"][-1]["status"], "FAIL")
        self.assertEqual(report["checks"][-1]["changed_paths"], ["fixture.py"])

    def test_stable_fingerprint_is_recorded(self):
        result, report = self.run_fixture(False)
        self.assertTrue(result)
        self.assertEqual(report["source_sha256"], report["source_sha256_after"])
