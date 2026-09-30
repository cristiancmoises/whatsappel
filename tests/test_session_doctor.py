# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only diagnostic decisions with explicit fixture replies, never a real account."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('session_doctor',ROOT/'scripts/doctor-session.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class SessionDoctorTests(unittest.TestCase):
    def fetch(self,state=None,status=200):
        calls=[]
        def reply(method,path,payload=None,limit=65536):
            calls.append((method,path))
            if path=='/health': return 200,{'version':'3.2.0-rc19'}
            if path.startswith('/transport/status'): return status,state or {}
            if path=='/profile/capabilities': return 200,{}
            if path=='/chats?v=2': return 200,{'version':2,'chats':[]}
            raise AssertionError('Unexpected diagnostic action')
        return reply,calls

    def state(self,**kw):
        result={'connected':True,'logged_in':True,'checked':True,'checking':False,
                'checked_age':0,'session_state':'ready'}
        result.update(kw); return result

    def test_reported_disconnected_account_does_not_probe_media(self):
        fetch,calls=self.fetch(self.state(connected=False,logged_in=False,session_state='disconnected'))
        out=m.collect(fetch,probe=True,pause=lambda _:None)
        self.assertFalse(out['backend_ready_for_probe'])
        self.assertEqual(out['media']['chats_checked'],0)
        self.assertFalse(out['media']['download_attempted'])
        self.assertEqual(out['media']['outcome'],'blocked-backend-session-not-verified-ready')
        self.assertTrue(all(method=='GET' for method,_ in calls))
        self.assertNotIn(('GET','/chats?v=2'),calls)

    def test_ready_account_can_run_bounded_explicit_sample(self):
        fetch,calls=self.fetch(self.state())
        out=m.collect(fetch,probe=True)
        self.assertTrue(out['backend_ready_for_probe'])
        self.assertEqual(out['media']['outcome'],'no-received-image-in-bounded-48h-sample')
        self.assertIn(('GET','/chats?v=2'),calls)

    def test_missing_stale_or_untyped_readiness_is_not_ready(self):
        for change in [{'checked':False},{'checking':True},{'checked_age':100},
                       {'checked_age':'0'},{'logged_in':1},{'logged_in':'true'},
                       {'connected':None},{'checked_age':float('nan')},{'checked_age':True}]:
            with self.subTest(change=change):
                fetch,calls=self.fetch(self.state(**change))
                out=m.collect(fetch,probe=True,pause=lambda _:None)
                self.assertFalse(out['backend_ready_for_probe'])
                self.assertNotIn(('GET','/chats?v=2'),calls)

    def test_status_authentication_failure_cannot_probe(self):
        fetch,calls=self.fetch(self.state(),401)
        self.assertFalse(m.collect(fetch,True)['backend_ready_for_probe'])
        self.assertNotIn(('GET','/chats?v=2'),calls)

    def test_sample_is_opt_in(self):
        fetch,calls=self.fetch(self.state())
        out=m.collect(fetch,False)
        self.assertNotIn('media',out)
        self.assertNotIn(('GET','/chats?v=2'),calls)

    def test_status_refresh_is_only_first_get(self):
        fetch,calls=self.fetch(self.state(checking=True))
        m.collect(fetch,False,pause=lambda _:None)
        status=[p for method,p in calls if p.startswith('/transport/status')]
        self.assertEqual(status[0],'/transport/status?refresh=1')
        self.assertEqual(len(status),16)
        self.assertTrue(all(p=='/transport/status' for p in status[1:]))

    def test_diagnostic_refuses_session_and_settings_writes(self):
        for path in ['/connect','/transport/connect','/transport/repair','/session/logout',
                     '/profile/consent','/transport/status?refresh=0','/transport/status?refresh=1&refresh=1']:
            self.assertFalse(m.route_allowed('POST',path))
            self.assertFalse(m.route_allowed('GET',path))
        self.assertTrue(m.route_allowed('GET','/transport/status?refresh=1'))

    def test_unknown_provider_text_and_identity_are_not_retained(self):
        state=self.state(); state.update(connection_state='PRIVATE_TOKEN',token='PRIVATE_TOKEN',jid='PRIVATE_JID')
        fetch,_=self.fetch(state)
        out=json.dumps(m.collect(fetch,False))
        self.assertNotIn('PRIVATE',out)

    def test_private_report_never_overwrites(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); path=root/'report.json'
            m.write_report(path,{'schema':1})
            with self.assertRaises(FileExistsError): m.write_report(path,{'schema':2})
            self.assertEqual(json.loads(path.read_text()),{'schema':1})
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
