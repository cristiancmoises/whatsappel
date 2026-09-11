# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only failure summaries must never rerun tests or reveal assertion values."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rc6_auditor', ROOT/'scripts/audit-workspace.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def log(self, data, name='emacs-ert.log'):
        p = self.root/name
        p.write_text(data)
        return p

    def report(self, checks=None, passed=False):
        checks = checks if checks is not None else [{'check':'emacs-ert','status':'FAIL'}]
        data = dict(schema=2, passed=passed, checks=checks)
        p = self.root/'report.json'
        p.write_text(json.dumps(data))
        return p

    def test_ert_numbered_and_summary_lines_deduplicated(self):
        p = self.log('   FAILED   94/108  whatsapp-workspace-bounded-history-and-expand (0.001 sec)\n   FAILED  whatsapp-workspace-bounded-history-and-expand\n')
        self.assertEqual(audit.native_failure_ids('emacs-ert',p), ['whatsapp-workspace-bounded-history-and-expand'])

    def test_ert_assertion_values_and_backtrace_not_copied(self):
        p = self.log('actual-value: fixture-secret\nTest one backtrace: fixture-secret\n  FAILED 1/2 one (0.1 sec)\n')
        result = audit.native_failure_ids('emacs-ert',p)
        self.assertEqual(result,['one'])
        self.assertNotIn('fixture-secret',str(result))

    def test_guile_output_uses_line_not_private_path_or_error_value(self):
        p = self.log('* FAIL: \nsource-file: /home/private/secret/tests/bridge-tests.scm\nsource-line: 118\nexpected-error: fixture-secret\n','guile-unit.log')
        self.assertEqual(audit.native_failure_ids('guile-unit',p),['tests/bridge-tests.scm:118'])

    def test_unlocated_guile_failure_has_safe_fallback(self):
        p = self.log('* FAIL: fixture-secret\n','guile-unit.log')
        result = audit.native_failure_ids('guile-unit',p)
        self.assertEqual(result,['Guile assertion (see guile-unit.log)'])

    def test_unknown_log_format_is_not_a_guessed_success(self):
        p = self.log('Debugger entered--Lisp error: fixture-secret\n')
        self.assertEqual(audit.native_failure_ids('emacs-ert',p),[])

    def test_unknown_check_does_not_open_file(self):
        with mock.patch.object(audit,'read_diagnostic_file',side_effect=AssertionError('unexpected read')):
            self.assertEqual(audit.native_failure_ids('not-native',self.root/'absent'),[])

    def test_output_at_most_twenty_unique_names(self):
        p = self.log(''.join(f' FAILED 1/99 case-{n}\n' for n in range(80)))
        self.assertEqual(len(audit.native_failure_ids('emacs-ert',p)),20)

    def test_escape_sequences_in_test_names_not_emitted(self):
        p = self.log(' FAILED \x1b[31msecret\n FAILED safe\n')
        self.assertEqual(audit.native_failure_ids('emacs-ert',p),['safe'])

    def test_missing_log_does_not_turn_failed_report_into_pass(self):
        p = self.report()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertFalse(audit.summarize_report(p))
        self.assertIn('FAIL: emacs-ert',out.getvalue())

    def test_passed_report_remains_passed(self):
        p = self.report([{'check':'example','status':'PASS'}],True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(audit.summarize_report(p))

    def test_report_log_path_is_never_followed(self):
        p = self.report([{'check':'emacs-ert','status':'FAIL','log':'../../secrets.env'}])
        self.log(' FAILED safe\n')
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertFalse(audit.summarize_report(p))
        self.assertIn('failed test: safe',out.getvalue())
        self.assertNotIn('secrets.env',out.getvalue())

    def test_empty_gate_list_rejected(self):
        p = self.report([],True)
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_duplicate_gate_names_rejected(self):
        p = self.report([{'check':'a','status':'FAIL'},{'check':'a','status':'PASS'}])
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_malicious_gate_name_rejected(self):
        p = self.report([{'check':'../../credentials','status':'FAIL'}])
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_unknown_status_rejected(self):
        p = self.report([{'check':'example','status':'MAYBE'}])
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_unhashable_status_rejected(self):
        p = self.report([{'check':'example','status':[]}])
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_success_flag_cannot_contradict_failed_gates(self):
        p = self.report(passed=True)
        with self.assertRaises(ValueError): audit.summarize_report(p)

    def test_duplicate_json_fields_refused(self):
        p = self.log('{"schema":2,"schema":2}', 'report.json')
        with self.assertRaisesRegex(ValueError,'Duplicate'): audit.summarize_report(p)

    def test_invalid_utf8_error_redacts_raw_bytes(self):
        p = self.root/'report.json';p.write_bytes(b'fixture-secret\xff')
        with self.assertRaises(ValueError) as error: audit.summarize_report(p)
        self.assertNotIn('fixture-secret',str(error.exception))

    def test_symlink_report_rejected(self):
        p = self.report();link = p.with_name('link');link.symlink_to(p)
        with self.assertRaises(ValueError): audit.summarize_report(link)

    def test_symlink_log_is_not_read(self):
        p = self.log(' FAILED fixture-secret\n','outside.log');link = self.root/'emacs-ert.log';link.symlink_to(p)
        self.assertEqual(audit.native_failure_ids('emacs-ert',link),[])

    def test_read_has_explicit_byte_limit(self):
        p = self.log('x'*100)
        with self.assertRaises(ValueError): audit.read_diagnostic_file(p,limit=99)

    def test_fifo_report_rejected_without_blocking(self):
        p = self.root/'report.json';os.mkfifo(p,0o600)
        with self.assertRaises(ValueError):audit.read_diagnostic_file(p)

    def test_summary_mode_executes_no_audit_or_tests(self):
        p = self.report()
        with mock.patch.object(audit,'run_audit',side_effect=AssertionError('tests reran')),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(audit.main(['--summarize',str(p)]),1)

    def test_summary_directory_reads_both_passes(self):
        for name in ('pass-1','pass-2'):
            d = self.root/name;d.mkdir()
            (d/'report.json').write_text(json.dumps(dict(schema=2,passed=False,checks=[dict(check='guile-unit',status='FAIL')])))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(audit.main(['--summarize',str(self.root)]),1)
        self.assertEqual(out.getvalue().count('FAIL: guile-unit'),2)

    def test_missing_second_pass_is_not_silently_ignored(self):
        d = self.root/'pass-1';d.mkdir();(d/'report.json').write_text(json.dumps(dict(schema=2,passed=True,checks=[dict(check='example',status='PASS')])))
        with contextlib.redirect_stdout(io.StringIO()),self.assertRaises(OSError):
            audit.main(['--summarize',str(self.root)])

if __name__ == '__main__':
    unittest.main()
