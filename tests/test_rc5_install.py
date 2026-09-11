# SPDX-License-Identifier: AGPL-3.0-only
"""Installer receipt/immutable-byte mechanics; receipts here are explicit fixtures."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

update=load('rc5_update','update-package.py');audit=load('rc5_audit','audit-workspace.py')

class Receipts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.candidate=self.root/'source';self.candidate.mkdir();(self.candidate/'file.py').write_text('fixture\n')
        self.expected=audit.source_fingerprint(self.candidate);self.plan=['fixture','source-integrity']
        self.ids=['one','two'];self.paths=[self.root/'one.json',self.root/'two.json']
        self.records=[dict(schema=2,run_id=rid,source=str(self.candidate),scope='full',passed=True,source_sha256=self.expected,source_sha256_after=self.expected,
                           checks=[dict(check=name,status='PASS',exit_code=0) for name in self.plan]) for rid in self.ids]
    def tearDown(self):self.tmp.cleanup()
    def verify(self):
        for path,record in zip(self.paths,self.records):path.write_text(json.dumps(record))
        return update.verify_double_audit(self.candidate,self.paths,self.ids,self.expected,'full',self.plan,audit.source_fingerprint)
    def test_exact_matching_fixture_receipts_accepted(self):self.verify()
    def test_only_one_receipt_refused(self):
        with self.assertRaises(update.UpdateError):update.verify_double_audit(self.candidate,self.paths[:1],self.ids,self.expected,'full',self.plan,audit.source_fingerprint)
    def test_duplicate_run_ids_refused(self):
        self.ids=['one','one']
        with self.assertRaises(update.UpdateError):self.verify()
    def test_wrong_run_id_refused(self):
        self.records[1]['run_id']='previous'
        with self.assertRaises(update.UpdateError):self.verify()
    def test_wrong_scope_refused(self):
        self.records[1]['scope']='changed'
        with self.assertRaises(update.UpdateError):self.verify()
    def test_wrong_source_refused(self):
        self.records[1]['source']=str(self.root/'other')
        with self.assertRaises(update.UpdateError):self.verify()
    def test_false_or_numeric_passed_refused(self):
        for value in [False,1,'true']:
            self.records[1]['passed']=value
            with self.subTest(value=value),self.assertRaises(update.UpdateError):self.verify()
    def test_partial_failed_blocked_or_boolean_exit_refused(self):
        for status,code in [('PARTIAL',0),('FAIL',0),('BLOCKED',0),('PASS',False),('PASS',1)]:
            self.records[1]['checks'][0].update(status=status,exit_code=code)
            with self.subTest(status=status,code=code),self.assertRaises(update.UpdateError):self.verify()
    def test_missing_duplicate_reordered_gates_refused(self):
        for values in [self.records[0]['checks'][:1],self.records[0]['checks']*2,list(reversed(self.records[0]['checks']))]:
            self.records[1]['checks']=values
            with self.subTest(values=values),self.assertRaises(update.UpdateError):self.verify()
    def test_different_pre_and_post_hashes_refused(self):
        self.records[1]['source_sha256_after']={'file.py':'a'*64}
        with self.assertRaises(update.UpdateError):self.verify()
    def test_after_audit_source_edit_refused(self):
        (self.candidate/'file.py').write_text('newer work')
        with self.assertRaises(update.UpdateError):self.verify()
    def test_missing_report_cannot_be_replaced_with_zero_exit(self):
        with self.assertRaises(update.UpdateError):update.verify_double_audit(self.candidate,self.paths,self.ids,self.expected,'full',self.plan,audit.source_fingerprint)

class FrozenPayload(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.target=self.root/'target';self.target.mkdir();(self.target/'whatsapp.el').write_bytes(b'old')
        self.bundle=self.root/'bundle';(self.bundle/'payload').mkdir(parents=True)
        (self.bundle/'payload/whatsapp.el').write_bytes(b'new')
        self.item=dict(path='whatsapp.el',before=hashlib.sha256(b'old').hexdigest(),after=hashlib.sha256(b'new').hexdigest(),mode=0o644)
    def tearDown(self):self.tmp.cleanup()
    def test_changed_bundle_bytes_are_not_installed(self):
        frozen={'whatsapp.el':b'new'};(self.bundle/'payload/whatsapp.el').write_bytes(b'unaudited')
        update.apply_files(self.target,self.bundle,[self.item],self.root/'backup',verified_payload=frozen)
        self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'new')
        update.restore_backup(self.root/'backup');self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'old')
    def test_wrong_frozen_digest_refused_before_backup(self):
        with self.assertRaises(update.UpdateError):update.apply_files(self.target,self.bundle,[self.item],self.root/'backup',verified_payload={'whatsapp.el':b'wrong'})
        self.assertFalse((self.root/'backup').exists());self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'old')
    def test_low_level_apply_also_checks_payload_digest(self):
        (self.bundle/'payload/whatsapp.el').write_bytes(b'wrong')
        with self.assertRaises(update.UpdateError):update.apply_files(self.target,self.bundle,[self.item],self.root/'backup')
        self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'old')
    def test_regular_streaming_hash_matches_reference(self):
        raw=b'synthetic'*500000;path=self.root/'large';path.write_bytes(raw)
        self.assertEqual(update.digest(path),hashlib.sha256(raw).hexdigest())
    def test_hashing_symlink_or_fifo_refused(self):
        link=self.root/'link';link.symlink_to(self.target/'whatsapp.el');fifo=self.root/'fifo';os.mkfifo(fifo)
        for path in [link,fifo]:
            with self.subTest(path=path),self.assertRaises(update.UpdateError):update.digest(path)
    def test_baseline_edit_in_unchanged_pq_input_detected(self):
        pq=self.target/'pqenv/src';pq.mkdir(parents=True);(pq/'lib.rs').write_text('independently newer')
        spec={'audit_inputs':['pqenv/src/lib.rs'],'files':[self.item]}
        before=update.installed_inputs(self.target,spec);(pq/'lib.rs').write_text('concurrent newer work')
        self.assertNotEqual(before,update.installed_inputs(self.target,spec))
    def test_more_than_four_known_baselines_supported_but_duplicates_refused(self):
        anchors=[hashlib.sha256(bytes([i])).hexdigest() for i in range(5)]
        self.assertEqual(update.compatible_baselines({'before':anchors[0],'compatible_before':anchors[1:]}),set(anchors))
        with self.assertRaises(update.UpdateError):update.compatible_baselines({'before':anchors[0],'compatible_before':[anchors[0]]})
    def test_unsafe_mode_rejected_by_bundle_verifier(self):
        spec=dict(format=1,version='fixture',audit_inputs=[],files=[dict(self.item,mode=0o4755)])
        (self.bundle/'manifest.json').write_text(json.dumps(spec))
        (self.bundle/'SHA256SUMS').write_text('\n'.join(update.digest(self.bundle/name)+'  '+name for name in ['manifest.json','payload/whatsapp.el'])+'\n')
        with self.assertRaises(update.UpdateError):update.verify_bundle(self.bundle)

class MainTransactionProof(unittest.TestCase):
    """Exercise main's integrity order with explicitly synthetic audit receipts.

    Native test execution is replaced ONLY inside these fixtures. They prove
    transaction ordering and refusal, not Emacs, Guile, or delivery behavior.
    """
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.target=self.root/'target';self.target.mkdir()
        inputs=['whatsapp.el','whatsapp-org.el','tests/client-tests.el','tests/whatsapp-org-tests.el',
                'scripts/publish.py','scripts/apply-update.py','scripts/audit-workspace.py','pqenv/src/lib.rs']
        for name in inputs:
            path=self.target/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes((ROOT/name).read_bytes() if name=='scripts/audit-workspace.py' else b'fixture before\n')
        (self.target/'.env').write_bytes(b'protected synthetic configuration')
        self.bundle=self.root/'bundle';(self.bundle/'payload/docs').mkdir(parents=True)
        for name,raw in [('whatsapp.el',b'fixture after\n'),('docs/fixture.md',b'audited documentation')]:
            (self.bundle/'payload'/name).write_bytes(raw)
        self.spec=dict(format=1,version='rc5-fixture',audit_inputs=inputs,files=[
            dict(path=name,before=update.digest(self.target/name) if (self.target/name).exists() else None,
                 after=update.digest(self.bundle/'payload'/name),mode=0o644)
            for name in ['whatsapp.el','docs/fixture.md']])
        (self.bundle/'manifest.json').write_text(json.dumps(self.spec))
        (self.bundle/'SHA256SUMS').write_text('\n'.join(update.digest(self.bundle/name)+'  '+name
            for name in ['manifest.json','payload/whatsapp.el','payload/docs/fixture.md'])+'\n')
        self.calls=0;self.change=None
    def tearDown(self):self.tmp.cleanup()
    def receipt(self,command,**kwargs):
        self.calls+=1
        index=next(i for i,v in enumerate(command) if str(v).endswith('/scripts/audit-workspace.py'))
        candidate=Path(command[index+1]);scope=command[command.index('--scope')+1]
        out=Path(command[command.index('--output')+1]);run_id=command[command.index('--run-id')+1]
        out.mkdir(mode=0o700)
        if self.change!='missing':
            hashes=audit.source_fingerprint(candidate)
            checks=[dict(check=n,status='PASS',exit_code=0) for n,_ in audit.checks(candidate,scope)]
            checks.append(dict(check='source-integrity',status='PASS',exit_code=0))
            (out/'report.json').write_text(json.dumps(dict(schema=2,run_id=run_id,scope=scope,source=str(candidate),
                passed=True,source_sha256=hashes,source_sha256_after=hashes,checks=checks)))
        if self.calls==2:
            if self.change=='bundle':(self.bundle/'payload/whatsapp.el').write_bytes(b'unaudited bundle')
            elif self.change=='code':(candidate/'whatsapp.el').write_bytes(b'unaudited candidate')
            elif self.change=='docs':(candidate/'docs/fixture.md').write_bytes(b'unaudited docs')
            elif self.change=='target-pq':(self.target/'pqenv/src/lib.rs').write_bytes(b'newer concurrent work')
        return subprocess.CompletedProcess(command,0)
    def run_main(self,*flags):
        with mock.patch.object(update.subprocess,'run',side_effect=self.receipt), contextlib.redirect_stdout(io.StringIO()):
            return update.main([str(self.target),'--bundle',str(self.bundle),*flags])
    def refuse(self,change):
        self.change=change
        with self.assertRaises((update.UpdateError,ValueError)):self.run_main('--apply')
        self.assertEqual(self.calls,2);self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'fixture before\n')
        self.assertEqual((self.target/'.env').read_bytes(),b'protected synthetic configuration')
        self.assertFalse(list(self.root.glob('whatsappel-backup-*')))
    def test_zero_exits_without_receipts_do_not_install(self):self.refuse('missing')
    def test_bundle_mutation_after_audits_does_not_install(self):self.refuse('bundle')
    def test_candidate_code_mutation_after_receipts_does_not_install(self):self.refuse('code')
    def test_candidate_document_mutation_does_not_install(self):self.refuse('docs')
    def test_concurrent_target_pq_change_does_not_install(self):self.refuse('target-pq')
    def test_audit_only_with_synthetic_receipts_never_installs(self):
        self.assertEqual(self.run_main('--audit-only'),0)
        self.assertEqual(self.calls,2);self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'fixture before\n')
        self.assertFalse(list(self.root.glob('whatsappel-backup-*')))
    def test_valid_synthetic_receipts_install_and_rollback_exact_payload(self):
        self.assertEqual(self.run_main('--apply'),0)
        self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'fixture after\n')
        self.assertEqual((self.target/'docs/fixture.md').read_bytes(),b'audited documentation')
        update.restore_backup(next(self.root.glob('whatsappel-backup-*')))
        self.assertEqual((self.target/'whatsapp.el').read_bytes(),b'fixture before\n')
        self.assertFalse((self.target/'docs/fixture.md').exists())
