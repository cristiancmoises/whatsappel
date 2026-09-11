# SPDX-License-Identifier: AGPL-3.0-only
"""Real process/log control and structured audit outcomes; no live services."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

audit=load('rc5_auditor','audit-workspace.py')

class StructuredTests(unittest.TestCase):
    def fixture(self,code):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'source';(source/'tests').mkdir(parents=True)
            (source/'tests/test_fixture.py').write_text('import unittest\n'+code)
            report=Path(tmp)/'results.json'
            result=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/run-tests.py'),'--source',str(source),'--report',str(report)],capture_output=True,timeout=8)
            return result,json.loads(report.read_text()),stat.S_IMODE(report.stat().st_mode)

    def test_pass_count_and_private_report(self):
        proc,report,mode=self.fixture('class T(unittest.TestCase):\n def test_ok(self):self.assertEqual(1,1)\n')
        self.assertEqual(proc.returncode,0);self.assertEqual(report['status'],'PASS');self.assertEqual(report['passed'],1);self.assertEqual(mode,0o600)

    def test_zero_discovery_is_failure(self):
        proc,report,_=self.fixture('')
        self.assertEqual(proc.returncode,1);self.assertEqual(report['discovered'],0);self.assertEqual(report['status'],'FAIL')

    def test_one_skip_does_not_pass(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n def test_skip(self):self.skipTest("fixture missing tool")\n')
        self.assertEqual(proc.returncode,2);self.assertEqual(report['status'],'PARTIAL');self.assertEqual(report['passed'],0);self.assertEqual(report['skipped'],1)

    def test_class_skip_does_not_invent_passed_cases(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n @classmethod\n def setUpClass(cls):raise unittest.SkipTest("fixture class skip")\n def test_a(self):pass\n def test_b(self):pass\n')
        self.assertEqual(proc.returncode,2);self.assertEqual(report['discovered'],2);self.assertEqual(report['run'],0);self.assertEqual(report['passed'],0)

    def test_mixed_success_and_skip_are_reported_separately(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n def test_a(self):pass\n def test_b(self):self.skipTest("fixture")\n')
        self.assertEqual(proc.returncode,2);self.assertEqual(report['passed'],1);self.assertEqual(report['skipped'],1)

    def test_unexpected_success_fails(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n @unittest.expectedFailure\n def test_a(self):pass\n')
        self.assertEqual(proc.returncode,1);self.assertEqual(report['unexpected_successes'],1)

    def test_expected_failure_is_partial_not_passed(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n @unittest.expectedFailure\n def test_a(self):self.fail("known fixture failure")\n')
        self.assertEqual(proc.returncode,2);self.assertEqual(report['expected_failures'],1);self.assertEqual(report['passed'],0)

    def test_failed_subtests_not_counted_as_passes(self):
        proc,report,_=self.fixture('class T(unittest.TestCase):\n def test_a(self):\n  for n in range(3):\n   with self.subTest(n=n):self.assertEqual(n,0)\n')
        self.assertEqual(proc.returncode,1);self.assertEqual(report['failures'],2);self.assertEqual(report['passed'],0);self.assertEqual(report['run'],1)

    def test_import_error_is_failure(self):
        proc,report,_=self.fixture('raise RuntimeError("fixture import failure")')
        self.assertEqual(proc.returncode,1);self.assertEqual(report['errors'],1)

    def test_preexisting_result_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            report=Path(tmp)/'result.json';report.write_text('keep')
            proc=subprocess.run([sys.executable,str(ROOT/'scripts/run-tests.py'),'--report',str(report)],capture_output=True,timeout=5)
            self.assertNotEqual(proc.returncode,0);self.assertEqual(report.read_text(),'keep')

    def test_missing_or_contradictory_receipt_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'report.json'
            self.assertEqual(audit.test_outcome(path,0)[0],'FAIL')
            path.write_text(json.dumps(dict(schema=1,status='PASS',discovered=1,run=1,passed=0,skipped=1,errors=0,failures=0,expected_failures=0,unexpected_successes=0)))
            self.assertEqual(audit.test_outcome(path,0)[0],'FAIL')

class ProcessSupervision(unittest.TestCase):
    def execute(self,code,limit=65536,timeout=3):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);log=root/'gate.log'
            result=audit.run_gate([sys.executable,'-I','-c',code],root,audit.clean_environment(),log,timeout=timeout,limit=limit)
            return result,log.read_bytes(),stat.S_IMODE(log.stat().st_mode)

    def test_success_log_private_and_complete(self):
        result,log,mode=self.execute('print("fixture-output")')
        self.assertEqual(result['exit_code'],0);self.assertEqual(log,b'fixture-output\n');self.assertEqual(mode,0o600)

    def test_nonzero_exit_preserved(self):
        result,_,_=self.execute('raise SystemExit(7)')
        self.assertEqual(result['exit_code'],7)

    def test_flood_is_bounded_and_gate_fails(self):
        result,log,_=self.execute('import sys;sys.stdout.buffer.write(b"x"*1048576)',limit=4096)
        self.assertEqual(result['exit_code'],125);self.assertEqual(len(log),4096);self.assertIn('limit',result['reason'])

    def test_deadline_does_not_wait_for_completion(self):
        result,_,_=self.execute('import time;time.sleep(60)',timeout=.15)
        self.assertEqual(result['exit_code'],124);self.assertLess(result['seconds'],2)

    def test_closed_pipes_do_not_disable_deadline(self):
        result,_,_=self.execute('import os,time;os.close(1);os.close(2);time.sleep(60)',timeout=.15)
        self.assertEqual(result['exit_code'],124);self.assertLess(result['seconds'],2)

    @unittest.skipUnless(os.name=='posix' and Path('/proc').is_dir(),'Linux process-group fixture')
    def test_deadline_kills_owned_grandchild(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);pidfile=root/'pid'
            code='import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);Path('+repr(str(pidfile))+').write_text(str(p.pid));time.sleep(60)'
            result=audit.run_gate([sys.executable,'-I','-c',code],root,audit.clean_environment(),root/'log',timeout=2)
            self.assertEqual(result['exit_code'],124)
            pid=int(pidfile.read_text());state=Path(f'/proc/{pid}/stat')
            for _ in range(20):
                if not state.exists() or state.read_text().split()[2]=='Z':break
                time.sleep(.02)
            self.assertTrue(not state.exists() or state.read_text().split()[2]=='Z')

    def test_existing_log_and_symlink_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);old=root/'old';old.write_bytes(b'keep');link=root/'link';link.symlink_to(old)
            for log in [old,link]:
                with self.subTest(log=log),self.assertRaises(OSError):audit.run_gate([sys.executable,'-c','pass'],root,{},log)
            self.assertEqual(old.read_bytes(),b'keep')

    def test_inherited_token_variables_removed(self):
        with mock.patch.dict(os.environ,{'WHATSAPPEL_TOKEN':'secret','GITHUB_TOKEN':'secret','WUZAPI_TOKEN':'secret','SSLKEYLOGFILE':'secret','EXAMPLE_PASSWORD':'secret','OPENAI_API_KEY':'secret','TOKEN':'secret','UNRELATED_FIXTURE':'keep'}):
            env=audit.clean_environment()
        for key in ['WHATSAPPEL_TOKEN','GITHUB_TOKEN','WUZAPI_TOKEN','SSLKEYLOGFILE','EXAMPLE_PASSWORD','OPENAI_API_KEY','TOKEN']:self.assertNotIn(key,env)
        self.assertEqual(env['UNRELATED_FIXTURE'],'keep')

class Fingerprints(unittest.TestCase):
    def test_make_shell_and_go_are_included_but_no_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['Makefile','setup.sh','helper.go','main.py','.env','README.md']:(root/name).write_text('fixture')
            self.assertEqual(set(audit.source_fingerprint(root)),{'Makefile','setup.sh','helper.go','main.py'})

    def test_source_links_and_fifo_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'link.py').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):audit.source_fingerprint(root)
            (root/'link.py').unlink();os.mkfifo(root/'pipe.py')
            with self.assertRaises(ValueError):audit.source_fingerprint(root)

    def test_source_link_directory_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'foreign').symlink_to('/tmp')
            with self.assertRaises(ValueError):audit.source_fingerprint(root)

    def test_audit_output_must_be_new_external_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'source';root.mkdir();out=Path(tmp)/'output';out.mkdir()
            with self.assertRaises(ValueError):audit.run_audit(root,root/'output')
            with self.assertRaises(FileExistsError):audit.run_audit(root,out)

    def test_full_native_gate_set_not_removed(self):
        plan={name for name,_ in audit.checks(ROOT,'full')}
        self.assertTrue({'emacs-byte-compile','emacs-ert','guile-unit','native-read-api','bridge-http','rust-tests','rust-clippy','mpv-local-decode'}<=plan)
