# SPDX-License-Identifier: AGPL-3.0-only
"""RC10 failure summaries: actual receipt files, no native-success substitution."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rc10_audit_diagnostics', ROOT/'scripts/audit-workspace.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PythonFailureDiagnostics(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root/'native-profile-api.log'
        self.receipt = self.log.with_suffix('.json')
        self.identity = 'test_profiles_http.ProfileHTTPTests.test_invalid_event_group_and_duplicate_keys'

    def save(self, **fields):
        value = {'schema': 1, 'status': 'FAIL', 'failed_tests': [self.identity], 'error_tests': []}
        value.update(fields)
        self.receipt.write_text(json.dumps(value), encoding='utf-8')

    def test_identifies_actual_failed_test_without_reading_traceback(self):
        self.save()
        self.log.write_text('PRIVATE_ASSERTION_AND_TOKEN')
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [self.identity])

    def test_also_supports_combined_python_gate(self):
        self.save(error_tests=['test_module.Case.test_error'])
        self.assertEqual(audit.native_failure_ids('python-regressions', self.log),
                         [self.identity, 'test_module.Case.test_error'])

    def test_only_bounded_unique_identifiers_are_printed(self):
        self.save(failed_tests=[self.identity]*3 + [f'test_module.Case.test_{i}' for i in range(30)])
        names = audit.native_failure_ids('native-profile-api', self.log)
        self.assertEqual(len(names), 20)
        self.assertEqual(names.count(self.identity), 1)

    def test_subtest_values_paths_control_characters_and_long_strings_omitted(self):
        self.save(failed_tests=[self.identity+' (secret=PRIVATE)', '/private/data',
                              self.identity+'\nPRIVATE', 'test_module.'+'x'*250, {}, 10])
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])

    def test_malformed_receipt_and_duplicate_json_fields_are_not_trusted(self):
        for text in ('{', '{"schema":1,"status":"FAIL","status":"PASS"}', '[]'):
            self.receipt.write_text(text)
            self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])

    def test_pass_receipt_cannot_manufacture_failure_names(self):
        self.save(status='PASS')
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])

    def test_bad_list_shapes_and_invalid_utf8_are_ignored(self):
        self.save(failed_tests={'private': self.identity})
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])
        self.receipt.write_bytes(b'\xff')
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])

    def test_symlink_and_oversized_receipts_are_refused(self):
        elsewhere = self.root/'outside.json'
        elsewhere.write_text('{}')
        self.receipt.symlink_to(elsewhere)
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])
        self.receipt.unlink()
        self.receipt.write_bytes(b' '*(8*1024*1024+1))
        self.assertEqual(audit.native_failure_ids('native-profile-api', self.log), [])

    def test_unknown_gate_does_not_read_receipt(self):
        with patch.object(audit, 'read_diagnostic_file', side_effect=AssertionError('unexpected read')):
            self.assertEqual(audit.native_failure_ids('unrelated', self.log), [])

    def test_readonly_summary_preserves_failed_result_and_ignores_report_log_path(self):
        self.save()
        report = {'schema': 2, 'passed': False, 'checks': [
            {'check': 'native-profile-api', 'status': 'FAIL', 'log': '/private/arbitrary'}]}
        path = self.root/'report.json'
        path.write_text(json.dumps(report))
        out = io.StringIO()
        with patch.object(audit, 'run_gate', side_effect=AssertionError('no test execution')):
            with contextlib.redirect_stdout(out):
                self.assertFalse(audit.summarize_report(path))
        self.assertIn(self.identity, out.getvalue())
        self.assertNotIn('/private/arbitrary', out.getvalue())

if __name__ == '__main__':
    unittest.main()
