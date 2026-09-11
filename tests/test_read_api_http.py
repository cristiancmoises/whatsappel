# SPDX-License-Identifier: AGPL-3.0-only
"""RC2 REAL Guile bridge integration; skipped only when Guile is unavailable.

The backend is a loopback wuzapi fake. No external account or WhatsApp messages.
"""
import base64
import json
import shutil
import time
import unittest
from urllib.parse import urlencode
import test_bridge_http as base

@unittest.skipUnless(shutil.which('guile'), 'Guile required: native read API and concurrency not validated here')
class ReadAPIHTTPTests(unittest.TestCase):
    # Reuse fixture lifecycle, not the base class's test methods.
    for _name in ('setUpClass','stop_bridge','stop_backend','request','chats','messages','webhook','post_webhook'):
        locals()[_name] = base.BridgeHTTPTests.__dict__[_name]

    def setUp(self):
        self.jobs=[]
        with self.backend.lock:
            self.backend.responses.clear();self.backend.download_delay=0
            self.backend.download_uri='data:image/png;base64,AA=='

    def tearDown(self):
        self.backend.download_delay=0
        for job in self.jobs:
            deadline=time.monotonic()+4
            while time.monotonic()<deadline:
                if self.request('GET','/media-job?'+urlencode({'id':job}))[0]!=202:break
                time.sleep(.05)

    def add_messages(self,chat,n=8):
        for i in range(n):
            self.assertEqual(self.post_webhook(self.webhook(chat,'read-%02d'%i,'text %d'%i))[0],200)

    def v2(self,chat,**query):
        return self.request('GET','/chat?'+urlencode({'jid':chat,'v':2,'read':0,'limit':3,**query}))

    def download(self):
        return self.request('POST','/download?async=1',{'kind':'image','Url':'https://mmg.whatsapp.net/fixture',
                            'MediaKey':base64.b64encode(bytes(32)).decode(),'Mimetype':'image/png','FileLength':1})

    def collect(self,job):
        deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            status,obj,_=self.request('GET','/media-job?'+urlencode({'id':job}))
            if status!=202:return status,obj
            time.sleep(.05)
        self.fail('Media result did not complete in bounded fixture time')

    def test_health_advertises_the_new_read_api(self):
        code,body,_=self.request('GET','/health',token=None)
        self.assertEqual(code,200);self.assertEqual(body['read_api'],2);self.assertTrue(body['async_media'])

    def test_window_is_bounded_and_read_zero_preserves_unread(self):
        chat='551122000101';self.add_messages(chat)
        before=self.chats()[chat]['unread']
        code,obj,_=self.v2(chat)
        self.assertEqual(code,200);self.assertEqual(len(obj['messages']),3)
        self.assertEqual(obj['total'],8);self.assertTrue(obj['has_more'])
        self.assertEqual(before,self.chats()[chat]['unread'])
        self.assertEqual([m['id'] for m in obj['messages']],['read-05','read-06','read-07'])

    def test_invalid_limits_are_rejected(self):
        for limit in ['0','-1','10001','1e2','+3','banana']:
            with self.subTest(limit=limit):self.assertEqual(self.v2('551122000102',limit=limit)[0],400)

    def test_chat_conditional_omits_unchanged_history_and_larger_window_is_distinct(self):
        chat='551122000103';self.add_messages(chat)
        _,first,_=self.v2(chat);_,same,_=self.v2(chat,since=first['revision'])
        self.assertTrue(same['unchanged']);self.assertNotIn('messages',same)
        _,older,_=self.v2(chat,limit=6,since=first['revision'])
        self.assertFalse(older['unchanged']);self.assertEqual(len(older['messages']),6)
        self.assertNotEqual(first['revision'],older['revision'])

    def test_list_revision_changes_on_new_message(self):
        _,first,_=self.request('GET','/chats?v=2')
        _,same,_=self.request('GET','/chats?'+urlencode({'v':2,'since':first['revision']}))
        self.assertTrue(same['unchanged']);self.assertNotIn('chats',same)
        self.add_messages('551122000104',1)
        _,changed,_=self.request('GET','/chats?'+urlencode({'v':2,'since':first['revision']}))
        self.assertFalse(changed['unchanged']);self.assertIn('chats',changed)

    def test_read_one_invalidates_unread_list_but_not_message_revision(self):
        chat='551122000105';self.add_messages(chat,1)
        _,before,_=self.v2(chat)
        _,root,_=self.request('GET','/chats?v=2')
        _,after,_=self.v2(chat,read=1,since=before['revision'])
        self.assertTrue(after['unchanged']);self.assertEqual(self.chats()[chat]['unread'],0)
        _,newroot,_=self.request('GET','/chats?'+urlencode({'v':2,'since':root['revision']}))
        self.assertFalse(newroot['unchanged'])

    def test_legacy_response_shape_remains_array(self):
        self.assertIsInstance(self.request('GET','/chats')[1],list)
        self.assertIsInstance(self.request('GET','/chat?jid=551122000106')[1],list)

    def test_slow_download_does_not_hold_up_chat_list_reads(self):
        self.backend.download_delay=2
        try:
            code,obj,_=self.download();self.assertEqual(code,202)
            self.jobs.append(obj['job'])
            start=time.monotonic();code,_,_=self.request('GET','/chats?v=2')
            elapsed=time.monotonic()-start
            self.assertEqual(code,200);self.assertLess(elapsed,1.0,'Chat reads waited behind a 2-second media fixture')
            code,obj=self.collect(self.jobs[0]);self.assertEqual(code,200)
            self.assertEqual(obj['data']['data']['Data'],'data:image/png;base64,AA==')
        finally:self.backend.download_delay=0

    def test_two_worker_bound_and_authentication(self):
        self.backend.download_delay=1
        for _ in range(2):
            code,obj,_=self.download();self.assertEqual(code,202);self.jobs.append(obj['job'])
        self.assertEqual(self.download()[0],429)
        self.assertEqual(self.request('GET','/media-job?'+urlencode({'id':self.jobs[0]}),token=None)[0],401)
        for job in self.jobs:self.assertEqual(self.collect(job)[0],200)
        self.assertEqual(self.request('GET','/media-job?'+urlencode({'id':self.jobs[0]}))[0],404)

    def test_invalid_download_metadata_never_reaches_upstream(self):
        before=len(self.backend.matching_requests('/chat/downloadimage'))
        code,obj,_=self.request('POST','/download?async=1',{'kind':'image','Url':'http://127.0.0.1/internal'})
        self.assertEqual(code,202);self.jobs.append(obj['job'])
        self.assertEqual(self.collect(obj['job'])[0],400)
        self.assertEqual(len(self.backend.matching_requests('/chat/downloadimage')),before)

if __name__=='__main__':unittest.main()
