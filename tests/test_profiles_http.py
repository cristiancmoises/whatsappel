# SPDX-License-Identifier: AGPL-3.0-only
"""Native Guile profile API against an authenticated loopback provider fixture.

Skipped explicitly when Guile is missing; not equivalent to worker-only tests.
"""
import json
import shutil
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode
import test_bridge_http as base

@unittest.skipUnless(shutil.which('guile'),'Guile required for actual profile bridge/event integration')
class ProfileHTTPTests(unittest.TestCase):
    for _name in ('setUpClass','stop_bridge','stop_backend','request','chats','messages','webhook','post_webhook'):
        locals()[_name]=base.BridgeHTTPTests.__dict__[_name]

    def setUp(self):
        self.jobs=[]
        self.post_webhook({'type':'Connected'})
        with self.backend.lock:
            self.backend.responses.clear();self.backend.requests.clear()
            self.backend.responses['/user/avatar']=(200,{'success':True,'data':{'URL':'https://pps.whatsapp.net/synthetic','ID':'1','Type':'preview'}})
            self.backend.responses['/user/info']=(200,{'success':True,'data':{'Users':{'123456789@s.whatsapp.net':{'Status':'Fixture About'}}}})

    def tearDown(self):
        for job in self.jobs:
            deadline=time.monotonic()+4
            while time.monotonic()<deadline:
                if self.request('GET','/profile/job?'+urlencode({'id':job}))[0]!=202:break
                time.sleep(.05)

    def snapshot(self,key='123456789'):
        code,body,_=self.request('GET','/profiles?'+urlencode({'jids':key}))
        self.assertEqual(code,200,body);return body

    def submit(self,kind,key='123456789',**extra):
        code,body,_=self.request('POST','/profile/request',{'kind':kind,'jid':key,**extra})
        if code==202:self.jobs.append(body['job'])
        return code,body

    def result(self,job):
        deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            code,body,_=self.request('GET','/profile/job?'+urlencode({'id':job}))
            if code!=202:return code,body
            time.sleep(.05)
        self.fail('Native profile job did not finish in fixture deadline')

    def test_capabilities_are_authenticated_and_truthful(self):
        self.assertEqual(self.request('GET','/profile/capabilities',token=None)[0],401)
        code,obj,_=self.request('GET','/profile/capabilities')
        self.assertEqual(code,200);self.assertEqual(obj['version'],1)
        self.assertFalse(obj['remote_idle']);self.assertFalse(obj['stories'])
        self.assertEqual(obj['max_contacts'],12)

    def test_initial_state_unknown_not_offline(self):
        p=self.snapshot()['profiles'][0]
        self.assertEqual(p['availability'],'unknown');self.assertEqual(p['activity'],'none');self.assertNotIn('last_seen',p)

    def test_flat_presence_and_hidden_lastseen(self):
        self.snapshot()
        self.assertEqual(self.post_webhook({'type':'Presence','from':'123456789@s.whatsapp.net','state':'online'})[0],200)
        self.assertEqual(self.snapshot()['profiles'][0]['availability'],'online')
        self.post_webhook({'type':'Presence','from':'123456789@s.whatsapp.net','state':'offline','last_seen':0})
        p=self.snapshot()['profiles'][0];self.assertEqual(p['availability'],'offline');self.assertNotIn('last_seen',p)

    def test_native_presence_timestamp_and_order(self):
        self.snapshot();now=int(time.time())
        self.post_webhook({'type':'Presence','event':{'From':'123456789@s.whatsapp.net','Unavailable':True,'LastSeen':now-100,'Timestamp':now}})
        self.post_webhook({'type':'Presence','event':{'From':'123456789@s.whatsapp.net','Unavailable':False,'Timestamp':now-10}})
        p=self.snapshot()['profiles'][0];self.assertEqual(p['availability'],'offline');self.assertEqual(p['last_seen'],now-100)

    def test_activity_does_not_claim_online(self):
        self.snapshot()
        self.post_webhook({'type':'ChatPresence','event':{'Sender':'123456789@s.whatsapp.net','Chat':'123456789@s.whatsapp.net','State':'composing','Media':'audio'}})
        p=self.snapshot()['profiles'][0];self.assertEqual(p['activity'],'recording');self.assertEqual(p['availability'],'unknown')
        self.post_webhook({'type':'ChatPresence','event':{'Sender':'123456789@s.whatsapp.net','State':'paused'}})
        self.assertEqual(self.snapshot()['profiles'][0]['activity'],'none')

    def test_picture_removal_increments_photo_only(self):
        before=self.snapshot()['profiles'][0]['photo_revision']
        _,chats,_=self.request('GET','/chats?v=2')
        self.post_webhook({'type':'Picture','event':{'JID':'123456789@s.whatsapp.net','Remove':True}})
        after=self.snapshot()['profiles'][0]
        self.assertEqual(after['photo_revision'],before+1);self.assertEqual(after['photo_state'],'removed')
        _,same,_=self.request('GET','/chats?v=2');self.assertEqual(chats['revision'],same['revision'])

    def test_reset_discards_old_presence(self):
        before=self.snapshot()['epoch']
        self.post_webhook({'type':'Presence','state':'online','from':'123456789@s.whatsapp.net'})
        self.post_webhook({'type':'Disconnected'})
        after=self.snapshot();self.assertNotEqual(after['epoch'],before);self.assertEqual(after['profiles'][0]['availability'],'unknown')

    def test_invalid_event_group_and_duplicate_keys(self):
        self.snapshot()
        self.assertEqual(self.post_webhook({'type':'Presence','state':'idle','from':'123456789@s.whatsapp.net'})[0],400)
        self.assertEqual(self.post_webhook({'type':'Presence','state':'online','from':'123456789@g.us'})[0],400)
        raw='{"type":"Presence","from":"123456789","state":"online","state":"offline"}'
        self.assertEqual(self.request('POST','/hook/'+base.BRIDGE_TOKEN,raw,token=None)[0],400)

    def test_unknown_unrequested_contacts_not_retained(self):
        self.post_webhook({'type':'Presence','state':'online','from':'111222333@s.whatsapp.net'})
        self.assertEqual(self.snapshot('111222333')['profiles'][0]['availability'],'unknown')

    def test_subscribe_opt_in_and_no_outgoing_online(self):
        self.assertEqual(self.submit('subscribe')[0],403)
        self.assertEqual(self.submit('subscribe','123456789@g.us',consent=True)[0],403)
        code,obj=self.submit('subscribe',consent=True);self.assertEqual(code,202)
        self.assertEqual(self.result(obj['job'])[1]['state'],'subscribed')
        requests=self.backend.matching_requests('/user/presence/subscribe')
        self.assertEqual(len(requests),1);self.assertEqual(requests[0][0],'POST')
        self.assertEqual(self.backend.matching_requests('/user/presence'),[])
        self.assertEqual(self.submit('subscribe',consent=True)[0],429)

    def test_avatar_actual_post_and_single_consumer_auth(self):
        self.snapshot();code,obj=self.submit('avatar');self.assertEqual(code,202)
        self.assertEqual(self.request('GET','/profile/job?'+urlencode({'id':obj['job']}),token='another-account-token')[0],401)
        code,result=self.result(obj['job']);self.assertEqual(code,200);self.assertEqual(result['state'],'ready')
        self.assertEqual(result['epoch'],self.snapshot()['epoch'])
        self.assertEqual(self.result(obj['job'])[0],404)
        req=self.backend.matching_requests('/user/avatar')[0]
        self.assertEqual(req[0],'POST');self.assertTrue(req[2]['Preview']);self.assertEqual(req[3],base.UPSTREAM_TOKEN)

    def test_provider_lowercase_photo_fields(self):
        self.snapshot()
        with self.backend.lock:
            self.backend.responses['/user/avatar'] = (200, {
                'success': True, 'data': {
                    'url': 'https://pps.whatsapp.net/synthetic',
                    'id': '1', 'type': 'preview', 'direct_path': '/synthetic', 'hash': None}})
        for kind in ('avatar', 'photo'):
            with self.subTest(kind=kind):
                code, job = self.submit(kind)
                self.assertEqual(code, 202)
                code, result = self.result(job['job'])
                self.assertEqual(code, 200)
                self.assertEqual(result['state'], 'ready')
                self.assertEqual(result['url'], 'https://pps.whatsapp.net/synthetic')
        requests = self.backend.matching_requests('/user/avatar')
        self.assertEqual([request[2]['Preview'] for request in requests], [True, False])

    def test_about_is_not_presence_or_stories(self):
        self.snapshot();code,obj=self.submit('about');self.assertEqual(code,202)
        result=self.result(obj['job'])[1];self.assertEqual(result['about'],'Fixture About')
        self.assertNotIn('availability',result)

    def test_unsupported_endpoint_is_feature_fallback(self):
        with self.backend.lock:self.backend.responses['/user/avatar']=(405,{'error':'wrong version'})
        code,obj=self.submit('avatar');self.assertEqual(code,202)
        self.assertEqual(self.result(obj['job'])[1]['state'],'unsupported')
        self.assertEqual(self.request('GET','/chats')[0],200)

    def test_message_webhook_still_routes_and_profile_does_not_mark_read(self):
        self.post_webhook(self.webhook('123456789','profile-test-msg','Fixture text'))
        before=self.chats()['123456789']['unread'];self.snapshot()
        self.post_webhook({'type':'Presence','state':'online','from':'123456789@s.whatsapp.net'})
        self.assertEqual(self.chats()['123456789']['unread'],before)

    def test_actual_worker_consumes_native_bridge_job_identifier(self):
        result=subprocess.run([sys.executable,'-I',str(base.ROOT/'scripts/profile-worker.py')],
            input=json.dumps({'url':f'http://127.0.0.1:{self.port}','token':base.BRIDGE_TOKEN,
                              'action':'about','jid':'123456789','timeout':5}).encode(),
            capture_output=True,timeout=8)
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertEqual(json.loads(result.stdout)['body']['about'],'Fixture About')

    def test_snapshot_limit_validation(self):
        for keys in ['',','.join(str(100+i) for i in range(13)),'123,123@s.whatsapp.net','../.env','12']:
            self.assertEqual(self.request('GET','/profiles?'+urlencode({'jids':keys}))[0],400)

    def test_two_slow_jobs_do_not_block_message_reads(self):
        original=base.MockHandler.respond
        def delayed(handler):
            if handler.path=='/user/avatar':time.sleep(1.2)
            return original(handler)
        with patch.object(base.MockHandler,'respond',delayed):
            self.assertEqual(self.submit('avatar','100001')[0],202)
            self.assertEqual(self.submit('avatar','100002')[0],202)
            self.assertEqual(self.submit('avatar','100003')[0],429)
            started=time.monotonic();self.assertEqual(self.request('GET','/chats?v=2')[0],200)
            self.assertLess(time.monotonic()-started,.7)
            for job in list(self.jobs):self.assertEqual(self.result(job)[0],200)

    def test_removal_while_lookup_pending_invalidates_result(self):
        self.snapshot();original=base.MockHandler.respond
        def delayed(handler):
            if handler.path=='/user/avatar':time.sleep(.6)
            return original(handler)
        with patch.object(base.MockHandler,'respond',delayed):
            _,obj=self.submit('avatar')
            self.post_webhook({'type':'Picture','event':{'JID':'123456789','Remove':True}})
            self.assertEqual(self.result(obj['job'])[1]['state'],'stale')

    def test_group_presence_validation_is_independent_of_cache(self):
        for key in ('123456789@g.us', '123456789-98765@g.us'):
            for cached in (False, True):
                for event in (
                    {'type': 'Presence', 'from': key, 'state': 'online'},
                    {'type': 'Presence', 'from': key, 'state': 'offline'},
                    {'type': 'Presence', 'event': {'From': key, 'Unavailable': False}},
                    {'type': 'Presence', 'event': {'From': key, 'Unavailable': True}},
                ):
                    with self.subTest(key=key, cached=cached, event=event):
                        self.post_webhook({'type': 'Connected'})
                        if cached:
                            self.snapshot(key)
                        code, body, _ = self.post_webhook(event)
                        self.assertEqual(code, 400)
                        self.assertFalse(body['success'])
                        self.assertFalse(body['ignored'])
                        record = self.snapshot(key)['profiles'][0]
                        self.assertEqual(record['availability'], 'unknown')
                        self.assertNotIn('last_seen', record)

    def test_invalid_direct_presence_is_rejected_before_cache_lookup(self):
        for cached in (False, True):
            for state in ('idle', 'away', '', 123, ['online']):
                with self.subTest(cached=cached, state=state):
                    self.post_webhook({'type': 'Connected'})
                    if cached:
                        self.snapshot()
                    self.assertEqual(self.post_webhook({
                        'type': 'Presence', 'from': '123456789@s.whatsapp.net',
                        'state': state})[0], 400)
                    self.assertEqual(self.snapshot()['profiles'][0]['availability'], 'unknown')

    def test_group_sender_cannot_be_direct_typing_presence(self):
        for cached in (False, True):
            self.post_webhook({'type': 'Connected'})
            key = '123456789@g.us'
            if cached:
                self.snapshot(key)
            code, body, _ = self.post_webhook({
                'type': 'ChatPresence', 'event': {'Sender': key, 'State': 'composing'}})
            self.assertEqual(code, 400)
            self.assertFalse(body['success'])
            self.assertEqual(self.snapshot(key)['profiles'][0]['activity'], 'none')

    def test_invalid_activity_fields_rejected_for_cached_and_uncached(self):
        for cached in (False, True):
            for extra in ({'State': 'idle'}, {'State': 'composing', 'Media': 'video'},
                          {'State': 'composing', 'Chat': '123456789@g.us'},
                          {'State': 'composing', 'Chat': '../private'}):
                with self.subTest(cached=cached, extra=extra):
                    self.post_webhook({'type': 'Connected'})
                    if cached:
                        self.snapshot()
                    event = {'Sender': '123456789@s.whatsapp.net', **extra}
                    self.assertEqual(self.post_webhook({'type': 'ChatPresence', 'event': event})[0], 400)
                    self.assertEqual(self.snapshot()['profiles'][0]['activity'], 'none')

    def test_invalid_picture_removal_rejected_before_cache_lookup(self):
        for cached in (False, True):
            for value in ('true', 1, ['false'], {}):
                with self.subTest(cached=cached, value=value):
                    self.post_webhook({'type': 'Connected'})
                    if cached:
                        self.snapshot()
                    self.assertEqual(self.post_webhook({'type': 'Picture', 'event': {
                        'JID': '123456789', 'Remove': value}})[0], 400)
                    record = self.snapshot()['profiles'][0]
                    self.assertEqual(record['photo_revision'], 0)
                    self.assertEqual(record['photo_state'], 'unknown')

    def test_invalid_timestamps_rejected_before_cache_lookup(self):
        for cached in (False, True):
            for stamp in ('not-a-time', -1, int(time.time()) + 3600, {}):
                with self.subTest(cached=cached, stamp=stamp):
                    self.post_webhook({'type': 'Connected'})
                    if cached:
                        self.snapshot()
                    self.assertEqual(self.post_webhook({'type': 'Presence', 'event': {
                        'From': '123456789', 'Unavailable': False, 'Timestamp': stamp}})[0], 400)
                    self.assertEqual(self.snapshot()['profiles'][0]['availability'], 'unknown')

    def test_valid_unrequested_event_families_still_ignore_without_retaining(self):
        for event in (
            {'type': 'Presence', 'from': '111222333', 'state': 'online'},
            {'type': 'Presence', 'event': {'From': '111222333', 'Unavailable': False}},
            {'type': 'ChatPresence', 'event': {'Sender': '111222333', 'State': 'composing'}},
            {'type': 'Picture', 'event': {'JID': '111222333', 'Remove': True}},
        ):
            with self.subTest(event=event):
                self.post_webhook({'type': 'Connected'})
                code, body, _ = self.post_webhook(event)
                self.assertEqual(code, 200)
                self.assertTrue(body['success'])
                self.assertTrue(body['ignored'])
                record = self.snapshot('111222333')['profiles'][0]
                self.assertEqual(record['availability'], 'unknown')
                self.assertEqual(record['activity'], 'none')
                self.assertEqual(record['photo_revision'], 0)

    def test_group_picture_removal_is_valid_without_group_presence(self):
        key = '123456789-98765@g.us'
        before = self.snapshot(key)['profiles'][0]
        code, body, _ = self.post_webhook({'type': 'Picture', 'event': {'JID': key, 'Remove': True}})
        self.assertEqual(code, 200)
        self.assertFalse(body['ignored'])
        after = self.snapshot(key)['profiles'][0]
        self.assertEqual(after['photo_revision'], before['photo_revision'] + 1)
        self.assertEqual(after['photo_state'], 'removed')
        self.assertEqual(after['availability'], 'unknown')
        self.assertEqual(after['activity'], 'none')

    def test_invalid_update_keeps_previous_valid_contact_state(self):
        self.snapshot()
        self.post_webhook({'type': 'Presence', 'from': '123456789', 'state': 'online'})
        self.post_webhook({'type': 'ChatPresence', 'event': {'Sender': '123456789', 'State': 'composing'}})
        self.assertEqual(self.post_webhook({'type': 'Presence', 'from': '123456789', 'state': 'idle'})[0], 400)
        self.assertEqual(self.post_webhook({'type': 'Picture', 'event': {'JID': '123456789', 'Remove': 'yes'}})[0], 400)
        record = self.snapshot()['profiles'][0]
        self.assertEqual(record['availability'], 'online')
        self.assertEqual(record['activity'], 'typing')
        self.assertEqual(record['photo_revision'], 0)

    def test_malformed_stale_event_is_invalid_not_ignored(self):
        self.snapshot()
        now = int(time.time())
        self.post_webhook({'type': 'Presence', 'from': '123456789', 'state': 'online', 'Timestamp': now})
        self.assertEqual(self.post_webhook({
            'type': 'Presence', 'from': '123456789', 'state': 'idle', 'Timestamp': now-10})[0], 400)
        code, body, _ = self.post_webhook({
            'type': 'Presence', 'from': '123456789', 'state': 'offline', 'Timestamp': now-10})
        self.assertEqual(code, 200)
        self.assertTrue(body['ignored'])
        self.assertEqual(self.snapshot()['profiles'][0]['availability'], 'online')

    def test_invalid_profile_events_do_not_change_messages_or_contact_order(self):
        self.post_webhook(self.webhook('123456789', 'rc10-kept-message', 'Synthetic kept text'))
        _, before, _ = self.request('GET', '/chats?v=2')
        with self.backend.lock:
            upstream_before = len(self.backend.requests)
        for event in (
            {'type': 'Presence', 'from': '111222333@g.us', 'state': 'online'},
            {'type': 'Presence', 'from': '111222333', 'state': 'idle'},
            {'type': 'ChatPresence', 'event': {'Sender': '111222333', 'State': 'invalid'}},
        ):
            self.assertEqual(self.post_webhook(event)[0], 400)
        _, after, _ = self.request('GET', '/chats?v=2')
        self.assertEqual(before, after)
        with self.backend.lock:
            self.assertEqual(len(self.backend.requests), upstream_before)

    def test_duplicate_profile_keys_rejected_without_cached_identity(self):
        for cached in (False, True):
            self.post_webhook({'type': 'Connected'})
            if cached:
                self.snapshot()
            raw = '{"type":"Presence","from":"123456789","state":"online","state":"offline"}'
            self.assertEqual(self.request('POST', '/hook/' + base.BRIDGE_TOKEN, raw, token=None)[0], 400)
            self.assertEqual(self.snapshot()['profiles'][0]['availability'], 'unknown')


    def test_about_uses_phone_jid_not_bare_user_number(self):
        self.snapshot()
        code,job=self.submit('about');self.assertEqual(code,202)
        code,result=self.result(job['job']);self.assertEqual(code,200)
        self.assertEqual(self.backend.matching_requests('/user/info')[-1][2]['Phone'],['123456789@s.whatsapp.net'])
        self.assertEqual(result['about'],'Fixture About')

    def test_about_preserves_lid_namespace(self):
        key='123456789@lid';self.snapshot(key)
        self.backend.responses['/user/info']=(200,{'success':True,'data':{'Users':{key:{'Status':'LID About'}}}})
        code,job=self.submit('about',key);self.assertEqual(code,202)
        code,result=self.result(job['job']);self.assertEqual(code,200)
        self.assertEqual(self.backend.matching_requests('/user/info')[-1][2]['Phone'],[key])
        self.assertEqual(result['about'],'LID About')

    def test_provider_denial_reason_does_not_expose_error_body(self):
        self.snapshot()
        self.backend.responses['/user/avatar']=(403,{'error':'PRIVATE_PROVIDER_FIELD'})
        code,job=self.submit('avatar');self.assertEqual(code,202)
        code,result=self.result(job['job']);self.assertEqual(code,200)
        self.assertEqual(result['state'],'unavailable');self.assertEqual(result['reason'],'provider-rejected')
        self.assertEqual(result['provider_http'],403)
        self.assertNotIn('PRIVATE_PROVIDER_FIELD',json.dumps(result))

if __name__=='__main__':unittest.main()
