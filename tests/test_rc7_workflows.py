# SPDX-License-Identifier: AGPL-3.0-only
"""RC7 local workflows. Synthetic native receipts are never production options."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

launch = load('rc7_launch', 'launch-whatsappel.py')
workflow = load('rc7_workflow', 'guix-workflow.py')
update = load('rc7_update', 'update-package.py')
commit = load('rc7_commit', 'commit-update.py')
publish = load('rc7_publish', 'publish.py')
TOKEN, URL = launch.ACCOUNT_KEYS

class AccountSelectionTests(unittest.TestCase):
    def test_init_only_keeps_no_external_pair(self):
        self.assertEqual(launch.account_environment({'HOME':'/fixture'}, {}), {'HOME':'/fixture'})
    def test_complete_file_pair(self):
        result = launch.account_environment({}, {TOKEN:'file-token', URL:'http://127.0.0.1:17337'})
        self.assertEqual((result[TOKEN], result[URL]), ('file-token','http://127.0.0.1:17337'))
    def test_environment_pair_wins_as_one_unit(self):
        result = launch.account_environment({TOKEN:'env-token', URL:'https://bridge.example.invalid'}, {TOKEN:'file-token', URL:'http://127.0.0.1:17337'})
        self.assertEqual((result[TOKEN],result[URL]),('env-token','https://bridge.example.invalid'))
    def test_environment_token_does_not_borrow_file_url(self):
        result = launch.account_environment({TOKEN:'env-token'}, {TOKEN:'file-token', URL:'https://different.example.invalid'})
        self.assertEqual(result[URL], launch.DEFAULT_ORIGIN)
    def test_file_token_uses_default_origin(self):
        self.assertEqual(launch.account_environment({}, {TOKEN:'file-token'})[URL], launch.DEFAULT_ORIGIN)
    def test_environment_url_does_not_borrow_file_token(self):
        with self.assertRaises(ValueError):
            launch.account_environment({URL:'https://other.example.invalid'}, {TOKEN:'file-token'})
    def test_file_url_does_not_borrow_init_token(self):
        with self.assertRaises(ValueError): launch.account_environment({}, {URL:'https://other.example.invalid'})
    def test_empty_external_token_does_not_fallback(self):
        with self.assertRaises(ValueError): launch.account_environment({TOKEN:''},{TOKEN:'fallback'})
    def test_empty_external_url_does_not_fallback(self):
        with self.assertRaises(ValueError): launch.account_environment({TOKEN:'valid',URL:''},{})
    def test_no_input_mutation(self):
        env={TOKEN:'a'}; settings={TOKEN:'b',URL:'https://example.invalid'}
        launch.account_environment(env,settings)
        self.assertEqual(env,{TOKEN:'a'});self.assertEqual(settings,{TOKEN:'b',URL:'https://example.invalid'})
    def test_invalid_tokens_redacted(self):
        for token in ['secret\nvalue', 'secret\tvalue','secret value','non-ascii-á','x'*4097]:
            with self.subTest(token_length=len(token)), self.assertRaises(ValueError) as err:
                launch.account_environment({TOKEN:token},{})
            self.assertNotIn(token,str(err.exception))
    def test_invalid_origins_redacted(self):
        for url in ['http://example.invalid','https://user:secret@example.invalid','file:///tmp/file', 'https://x/?secret', 'https://x/#secret','https://x/secret','http://127.0.0.1:0','https://x:99999','https://x\nsecret']:
            with self.subTest(url=url), self.assertRaises(ValueError) as err:
                launch.account_environment({TOKEN:'sensitive',URL:url},{})
            self.assertNotIn('sensitive',str(err.exception));self.assertNotIn(url,str(err.exception))
    def test_loopback_and_https_accepted(self):
        for url in ['http://localhost:7337','http://[::1]:7337','http://127.0.0.1:17337','https://remote.example.invalid:443/']:
            self.assertEqual(launch.account_environment({TOKEN:'valid',URL:url},{})[URL],url.rstrip('/'))
    def test_main_exec_receives_pair_but_argv_contains_no_token(self):
        with mock.patch.dict(os.environ,{TOKEN:'env-token'},clear=True),mock.patch.object(launch,'literal_environment',return_value={TOKEN:'file-token',URL:'https://file.example.invalid'}),mock.patch.object(launch.shutil,'which',return_value='/fixture/emacs'),mock.patch.object(launch.os,'execve') as execute:
            launch.main([])
        args=execute.call_args.args
        self.assertEqual(args[2][TOKEN],'env-token');self.assertEqual(args[2][URL],launch.DEFAULT_ORIGIN)
        self.assertNotIn('env-token',' '.join(args[1]));self.assertNotIn('file-token',' '.join(args[1]))
    def test_bad_pair_never_launches(self):
        with mock.patch.dict(os.environ,{URL:'https://bad.example.invalid'},clear=True),mock.patch.object(launch,'literal_environment',return_value={TOKEN:'old'}),mock.patch.object(launch.shutil,'which',return_value='/fixture/emacs'),mock.patch.object(launch.os,'execve') as execute:
            with self.assertRaises(ValueError): launch.main([])
            execute.assert_not_called()
    def test_check_does_not_open_gui(self):
        with mock.patch.dict(os.environ,{TOKEN:'secret'},clear=True),mock.patch.object(launch,'literal_environment',return_value={}),mock.patch.object(launch.shutil,'which',return_value='/fixture/emacs'),mock.patch.object(launch.os,'execve') as execute,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(launch.main(['--check']),0)
            execute.assert_not_called();self.assertNotIn('secret',output.getvalue())

class WorkflowArguments(unittest.TestCase):
    def setUp(self):
        self.inst=mock.Mock(UpdateError=update.UpdateError)
        self.inst.main.return_value=0
    def call(self,*args):
        with mock.patch.object(workflow,'load_installer',return_value=self.inst),contextlib.redirect_stdout(io.StringIO()):
            return workflow.main(list(args))
    def test_update_always_full_audit_and_desktop(self):
        self.call('/tmp/fixture')
        args=self.inst.main.call_args.args[0]
        self.assertIn('--full-audit',args);self.assertIn('--apply',args);self.assertIn('--desktop',args)
    def test_audit_only_has_no_apply(self):
        self.call('/tmp/fixture','--audit-only')
        args=self.inst.main.call_args.args[0]
        self.assertIn('--full-audit',args);self.assertIn('--audit-only',args);self.assertNotIn('--apply',args)
    def test_check_does_not_audit(self):
        self.call('/tmp/fixture','--check')
        args=self.inst.main.call_args.args[0]
        self.assertNotIn('--apply',args);self.assertNotIn('--audit-only',args)
    def test_defaults_to_existing_home_checkout(self):
        self.call('--check');self.assertEqual(self.inst.main.call_args.args[0][0],str(Path.home()/'whatsappel'))
    def test_existing_errors_are_concise(self):
        self.inst.main.side_effect=update.UpdateError('native failed')
        with self.assertRaisesRegex(ValueError,'native failed'): self.call('/tmp/fixture')
    def test_rejects_store_paths(self):
        for p in ['/gnu/store','/gnu/store/fixture/source']:
            with self.subTest(path=p),self.assertRaises(ValueError): self.call(p)
    def test_rejects_control_in_destination(self):
        with self.assertRaises(ValueError):self.call('/tmp/foo\nbar')
    def test_conflicting_modes_are_rejected(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):self.call('--check','--audit-only')

class FreshTransactionTests(unittest.TestCase):
    """Native gate is mocked ONLY to test file publication/rollback mechanics."""
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.bundle=self.root/'bundle';self.source=self.bundle/'source';self.source.mkdir(parents=True)
        (self.source/'whatsapp.el').write_bytes(b'fixture-source\n')
        self.sha=hashlib.sha256((self.source/'whatsapp.el').read_bytes()).hexdigest()
        (self.bundle/'SOURCE_SHA256SUMS').write_text(self.sha+'  whatsapp.el\n')
        (self.bundle/'manifest.json').write_text('{}')
        (self.bundle/'SHA256SUMS').write_text('fixture-integrity')
        self.spec={'files':[{'path':'whatsapp.el','after':self.sha}]}
        self.target=self.root/'new-install'
    def install(self, audit_only=False):
        with mock.patch.object(update,'verify_bundle',return_value=self.spec),mock.patch.object(update,'main',return_value=0) as gate,mock.patch.object(update,'apply_files') as desktop,contextlib.redirect_stdout(io.StringIO()):
            result=workflow.install_new(self.target,self.bundle,update,self.spec,audit_only)
            return result,gate,desktop
    def test_snapshot_integrity(self):
        self.assertEqual(workflow.snapshot_entries(self.bundle,update),{'whatsapp.el':self.sha})
    def test_tampered_source_refused(self):
        (self.source/'whatsapp.el').write_text('modified')
        with self.assertRaises(ValueError):workflow.snapshot_entries(self.bundle,update)
    def test_unindexed_source_refused(self):
        (self.source/'surprise').write_text('new')
        with self.assertRaises(ValueError):workflow.snapshot_entries(self.bundle,update)
    def test_duplicate_source_index_refused(self):
        p=self.bundle/'SOURCE_SHA256SUMS';p.write_text(p.read_text()*2)
        with self.assertRaises(ValueError):workflow.snapshot_entries(self.bundle,update)
    def test_source_symlink_refused(self):
        p=self.source/'whatsapp.el';p.unlink();p.symlink_to('/etc/passwd')
        with self.assertRaises(update.UpdateError):workflow.snapshot_entries(self.bundle,update)
    def test_new_transaction_passes_through_full_gate(self):
        result,gate,desktop=self.install()
        self.assertEqual(result,0);self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'fixture-source\n')
        self.assertIn('--full-audit',gate.call_args.args[0]);self.assertIn('--audit-only',gate.call_args.args[0])
        self.assertEqual(desktop.call_args.args[0],self.target);self.assertTrue(desktop.call_args.kwargs['desktop'])
    def test_fresh_audit_only_creates_no_destination(self):
        _,_,desktop=self.install(True);self.assertFalse(self.target.exists());desktop.assert_not_called()
    def test_failed_native_gate_leaves_target_absent(self):
        with mock.patch.object(update,'main',side_effect=update.UpdateError('native failure')):
            with self.assertRaises(update.UpdateError):workflow.install_new(self.target,self.bundle,update,self.spec)
        self.assertFalse(self.target.exists());self.assertEqual(list(self.root.glob('.whatsappel-new-*')),[])
    def test_existing_destination_never_replaced(self):
        self.target.mkdir();(self.target/'precious').write_text('keep')
        with self.assertRaises(ValueError):self.install()
        self.assertEqual((self.target/'precious').read_text(),'keep')
    def test_snapshot_vs_payload_mismatch_rejected(self):
        self.spec['files'][0]['after']='0'*64
        with self.assertRaises(ValueError):self.install()
        self.assertFalse(self.target.exists())
    def test_changed_stage_after_gate_refused(self):
        def mutate(args): (Path(args[0])/'whatsapp.el').write_text('changed');return 0
        with mock.patch.object(update,'main',side_effect=mutate),mock.patch.object(update,'verify_bundle',return_value=self.spec):
            with self.assertRaises(ValueError):workflow.install_new(self.target,self.bundle,update,self.spec)
        self.assertFalse(self.target.exists())
    def test_atomic_no_replace_refuses_even_empty_directory(self):
        source=self.root/'stage';source.mkdir();(source/'file').write_text('data');self.target.mkdir()
        with self.assertRaises(ValueError):workflow.rename_new_directory(source,self.target)
        self.assertTrue((source/'file').is_file());self.assertEqual(list(self.target.iterdir()),[])
    def test_atomic_no_replace_works_in_path_with_spaces(self):
        source=self.root/'with spaces';source.mkdir();dest=self.root/'new with spaces'
        workflow.rename_new_directory(source,dest);self.assertTrue(dest.is_dir());self.assertFalse(source.exists())

@unittest.skipUnless(shutil.which('git'), 'Git unavailable')
class CommittedBaselineTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.repo=self.root/'repo';self.repo.mkdir()
        self.git('init','-b','main');self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.invalid')
        self.raw=b';;; unicode: \xc3\xa1\r\n'
        (self.repo/'whatsapp.el').write_bytes(self.raw)
        self.git('add','whatsapp.el');self.git('commit','-m','fixture')
    def git(self,*args):return subprocess.run(['git','-C',str(self.repo),*args],check=True,capture_output=True).stdout
    def test_git_blob_preserves_crlf_and_utf8(self):self.assertEqual(commit.git_blob(self.repo,'whatsapp.el'),self.raw)
    def test_blob_ignores_uncommitted_changes(self):
        (self.repo/'whatsapp.el').write_text('local newer work')
        self.assertEqual(commit.git_blob(self.repo,'whatsapp.el'),self.raw)
    def test_missing_blob_has_concise_error(self):
        with self.assertRaisesRegex(ValueError,'baseline blob'):commit.git_blob(self.repo,'missing')
    def test_four_expected_destinations(self):
        self.assertEqual(set(publish.DESTINATIONS),{'forgejo-co','forgejo-com-br','github','codeberg'})
        self.assertEqual(publish.DESTINATIONS['codeberg'][:2],('codeberg.org','berkeley'))
        for key in ('forgejo-co','forgejo-com-br','github'):self.assertEqual(publish.DESTINATIONS[key][1],'cristiancmoises')


@unittest.skipUnless(shutil.which('git'), 'Git unavailable')
class PublicationCheckTests(unittest.TestCase):
    setUp = CommittedBaselineTests.setUp
    git = CommittedBaselineTests.git
    def make_bundle(self, unknown=False):
        bundle=self.root/'bundle';(bundle/'payload').mkdir(parents=True);(bundle/'scripts').mkdir()
        (bundle/'scripts/update-package.py').write_bytes((ROOT/'scripts/update-package.py').read_bytes())
        (bundle/'payload/whatsapp.el').write_bytes(b'new candidate\n')
        before='0'*64 if unknown else hashlib.sha256(self.raw).hexdigest()
        entry={'path':'whatsapp.el','before':before,'after':update.digest(bundle/'payload/whatsapp.el'),'mode':0o644}
        (bundle/'manifest.json').write_text(json.dumps({'format':1,'version':'fixture','audit_inputs':['whatsapp.el'],'files':[entry]}))
        files=['manifest.json','scripts/update-package.py','payload/whatsapp.el']
        (bundle/'SHA256SUMS').write_text(''.join(update.digest(bundle/f)+'  '+f+'\n' for f in files))
        return bundle
    def test_check_creates_no_worktree_commit_or_network(self):
        bundle=self.make_bundle();work=self.root/'publication';before=self.git('rev-parse','HEAD')
        (self.repo/'whatsapp.el').write_text('keep dirty original')
        with mock.patch.object(commit.subprocess,'call',side_effect=AssertionError('No publisher expected')),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(commit.main([str(self.repo),'--bundle',str(bundle),'--worktree',str(work),'--check']),0)
        self.assertFalse(work.exists());self.assertEqual(self.git('rev-parse','HEAD'),before)
        self.assertEqual((self.repo/'whatsapp.el').read_text(),'keep dirty original')
    def test_unknown_committed_baseline_refused_before_worktree(self):
        bundle=self.make_bundle(True);work=self.root/'publication'
        with self.assertRaisesRegex(ValueError,'Committed HEAD'):
            commit.main([str(self.repo),'--bundle',str(bundle),'--worktree',str(work),'--check'])
        self.assertFalse(work.exists())
    def test_nested_directory_in_other_repo_refused(self):
        bundle=self.make_bundle();child=self.repo/'nested';child.mkdir()
        with self.assertRaisesRegex(ValueError,'exact Git project root'):
            commit.main([str(child),'--bundle',str(bundle),'--check'])
    def test_non_git_read_only_check_refuses_network_clone(self):
        bundle=self.make_bundle();plain=self.root/'plain';plain.mkdir()
        # Global fixture identity is provided only for the read-only check fixture.
        original=commit.git
        def configured(repo,*args,**kwargs):
            if args[:2]==('config','--get'):
                return mock.Mock(stdout='Fixture' if args[-1]=='user.name' else 'fixture@example.invalid')
            return original(repo,*args,**kwargs)
        with mock.patch.object(commit,'git',side_effect=configured),self.assertRaisesRegex(ValueError,'Read-only check'):
            commit.main([str(plain),'--bundle',str(bundle),'--check'])

if __name__ == '__main__': unittest.main()
