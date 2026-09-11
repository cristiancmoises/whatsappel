# SPDX-License-Identifier: AGPL-3.0-only
"""Real Guile HTTP transport contracts using a synthetic upstream, not WhatsApp."""
import base64
import copy
import json
import shutil
import time
import unittest
from urllib.parse import urlencode
import test_bridge_http as base

@unittest.skipUnless(shutil.which('guile'), 'Guile required for native transport integration')
class TransportHTTPTests(unittest.TestCase):
    for _name in ('setUpClass','stop_bridge','stop_backend','request','chats','messages','webhook','post_webhook'):
        locals()[_name]=base.BridgeHTTPTests.__dict__[_name]
    def setUp(self):
        with self.backend.lock:
            self.backend.responses.clear();self.backend.download_delay=0
    def event(self): return self.webhook('551177000011','transport-fixture-'+self._testMethodName,'Olá mensagem')
    def hook(self,body,kind='application/json'):
        return self.request('POST','/hook/'+base.BRIDGE_TOKEN,body,token=None,content_type=kind)
    def test_direct_event(self):
        e=self.event();self.assertEqual(self.hook(e)[0],200);self.assertIn(e['event']['Info']['ID'],[m['id'] for m in self.messages('551177000011')])
    def test_json_envelope(self):
        e=self.event();self.assertEqual(self.hook({'jsonData':json.dumps(e),'userID':'synthetic'})[0],200);self.assertIn(e['event']['Info']['ID'],[m['id'] for m in self.messages('551177000011')])
    def test_form_envelope(self):
        e=self.event();self.assertEqual(self.hook(urlencode({'jsonData':json.dumps(e)}),'application/x-www-form-urlencoded')[0],200);self.assertIn(e['event']['Info']['ID'],[m['id'] for m in self.messages('551177000011')])
    def test_duplicate_json_envelope_refused(self):
        self.assertEqual(self.hook(b'{"jsonData":"{}","jsonData":"{}"}')[0],400)
    def test_duplicate_form_envelope_refused(self):self.assertEqual(self.hook('jsonData=%7B%7D&jsonData=%7B%7D','application/x-www-form-urlencoded')[0],400)
    def test_ambiguous_envelope_refused(self):self.assertEqual(self.hook({'jsonData':json.dumps(self.event()),'type':'Message'})[0],400)
    def multipart(self,e,duplicate=False):
        boundary='synthetic-boundary'
        part=b'--synthetic-boundary\r\nContent-Disposition: form-data; name="jsonData"\r\n\r\n'+json.dumps(e).encode()+b'\r\n'
        raw=b'--synthetic-boundary\r\nContent-Disposition: form-data; name="file"; filename="never-written.png"\r\nContent-Type: image/png\r\n\r\n\xff\xfe\x00binary\r\n'+part+(part if duplicate else b'')+b'--synthetic-boundary--\r\n'
        return raw,'multipart/form-data; boundary='+boundary
    def test_binary_multipart_metadata_received(self):
        e=self.event();raw,kind=self.multipart(e);self.assertEqual(self.hook(raw,kind)[0],200);self.assertIn(e['event']['Info']['ID'],[m['id'] for m in self.messages('551177000011')])
    def test_duplicate_multipart_metadata_refused(self):
        raw,kind=self.multipart(self.event(),True);self.assertEqual(self.hook(raw,kind)[0],400)
    def test_missing_multipart_terminator_refused(self):
        raw,kind=self.multipart(self.event());self.assertEqual(self.hook(raw[:-30],kind)[0],400)
    def test_ephemeral_image_metadata_preserved(self):
        e=self.event();fields={'url':'https://mmg.whatsapp.net/fixture','mediaKey':base64.b64encode(bytes(32)).decode(),'mimetype':'image/png','fileLength':1}
        e['event']['Message']={'ephemeralMessage':{'message':{'imageMessage':fields}}}
        self.assertEqual(self.hook(e)[0],200);m=next(m for m in self.messages('551177000011') if m['id']==e['event']['Info']['ID']);self.assertEqual(m['kind'],'image');self.assertEqual(m['media']['MediaKey'],fields['mediaKey'])
    def test_document_caption_wrapper(self):
        e=self.event();e['event']['Message']={'documentWithCaptionMessage':{'message':{'documentMessage':{'url':'https://mmg.whatsapp.net/f','caption':'file','mimetype':'text/plain'}}}}
        self.assertEqual(self.hook(e)[0],200);m=next(m for m in self.messages('551177000011') if m['id']==e['event']['Info']['ID']);self.assertEqual(m['kind'],'document');self.assertEqual(m['caption'],'file')
    def test_view_once_not_unwrapped(self):
        e=self.event();e['event']['Message']={'viewOnceMessage':{'message':{'imageMessage':{'url':'https://mmg.whatsapp.net/private'}}}}
        self.hook(e);matches=[m for m in self.messages('551177000011') if m['id']==e['event']['Info']['ID']];self.assertTrue(not matches or not matches[0].get('media'))
    def test_accepted_id_required_no_successful_local_echo(self):
        for obj in ({'success':True,'data':{}},{'success':True,'data':{'Id':'bad','success':False}},{'success':True,'data':{'Id':'a','ID':'b'}}):
            with self.subTest(obj=obj):
                self.backend.responses['/chat/send/text']=(200,obj);code,body,_=self.request('POST','/send',{'to':'551177000012','body':'not confirmed'});self.assertEqual(code,502);self.assertTrue(body['uncertain'])
        self.assertEqual(self.messages('551177000012'),[])
    def test_real_id_marks_accepted_not_delivered(self):
        code,body,_=self.request('POST','/send',{'to':'551177000013','body':'fixture'});self.assertEqual(code,200);self.assertEqual(body['delivery'],'accepted');self.assertEqual(self.messages('551177000013')[-1]['delivery'],'accepted')
    def test_lid_send_retains_namespace_and_matching_history_key(self):
        lid = '123456789012345@lid'
        before = len(self.backend.matching_requests('/chat/send/text'))
        code, body, _ = self.request('POST', '/send', {'to': lid, 'body': 'synthetic LID fixture'})
        self.assertEqual(code, 200)
        sent = self.backend.matching_requests('/chat/send/text')
        self.assertEqual(len(sent), before + 1)
        self.assertEqual(sent[-1][2]['Phone'], lid)
        records = self.messages(lid)
        self.assertEqual(records[-1]['id'], body['message_id'])
        self.assertEqual(records[-1]['delivery'], 'accepted')
        self.assertEqual(self.messages('123456789012345'), [])

    def test_lid_receipt_does_not_update_same_digits_phone_chat(self):
        digits, lid = '123456789012346', '123456789012346@lid'
        _, first, _ = self.request('POST', '/send', {'to': lid, 'body': 'synthetic opaque fixture'})
        _, second, _ = self.request('POST', '/send', {'to': digits, 'body': 'synthetic phone fixture'})
        code, _, _ = self.hook({'type':'ReadReceipt', 'state':'Delivered',
                                'event':{'Chat':lid, 'MessageIDs':[first['message_id']]}})
        self.assertEqual(code, 200)
        self.assertEqual(self.messages(lid)[-1]['delivery'], 'delivered')
        self.assertEqual(self.messages(digits)[-1]['delivery'], 'accepted')

    def test_receipts_monotonic_no_new_records(self):
        _,body,_=self.request('POST','/send',{'to':'551177000014','body':'fixture'});mid=body['message_id']
        for state in ('Delivered','Read','Delivered','ReadSelf'):
            self.assertEqual(self.hook({'type':'ReadReceipt','state':state,'event':{'Chat':'551177000014@s.whatsapp.net','MessageIDs':[mid]}})[0],200)
        records=self.messages('551177000014');self.assertEqual(len(records),1);self.assertEqual(records[0]['delivery'],'read')
    def test_unknown_receipt_no_new_chat(self):
        self.assertEqual(self.hook({'type':'ReadReceipt','state':'Delivered','event':{'Chat':'551177000015@s.whatsapp.net','MessageIDs':['none']}})[0],200);self.assertNotIn('551177000015',self.chats())
    def test_receipt_requires_webhook_auth(self):
        self.assertEqual(self.request('POST','/hook/wrong',{'type':'ReadReceipt'},token=None)[0],401)
    def test_status_is_redacted_and_no_connect(self):
        self.backend.responses['/session/status']=(200,{'success':True,'data':{'connected':False,'loggedIn':True,'token':'DO_NOT_EXPOSE','jid':'DO_NOT_EXPOSE','qrcode':'DO_NOT_EXPOSE'}})
        self.backend.responses['/webhook']=(200,{'success':True,'data':{'webhook':'','subscribe':['Presence']}})
        before=len(self.backend.matching_requests('/session/connect'))
        _,o,_=self.request('GET','/transport/status')
        end=time.monotonic()+6
        while o.get('checking') and time.monotonic()<end:
            time.sleep(.05);_,o,_=self.request('GET','/transport/status')
        # Cached checks may originate from earlier explicit repair fixtures; never
        # assert freshness of a sample solely because the HTTP operation succeeded.
        self.assertNotIn('DO_NOT_EXPOSE',json.dumps(o));self.assertEqual(len(self.backend.matching_requests('/session/connect')),before)
        self.assertIn(o.get('connection_state'),('yes','no','unknown'))
    def test_repair_auth_and_confirmation_precede_upstream(self):
        before=len(self.backend.matching_requests('/webhook'))
        self.assertEqual(self.request('POST','/transport/repair',{'confirm':True},token=None)[0],401)
        for obj in ({},{'confirm':False},{'confirm':'true'},{'confirm':True,'replace':'yes'},{'confirm':True,'unknown':1}):
            self.assertEqual(self.request('POST','/transport/repair',obj)[0],400)
        self.assertEqual(len(self.backend.matching_requests('/webhook')),before)
    def test_repair_preserves_events_and_never_connects(self):
        callback=f'http://127.0.0.1:{self.port}/hook/{base.BRIDGE_TOKEN}'
        events=['Presence','Picture','Message','ReadReceipt']
        self.backend.responses['/webhook']=(200,{'success':True,'data':{'webhook':callback,'subscribe':events}})
        end=time.monotonic()+5
        while time.monotonic()<end:
            code,_,_=self.request('POST','/transport/repair',{'confirm':True,'replace':False})
            if code==202:break
            self.assertEqual(code,429);time.sleep(.05)
        self.assertEqual(code,202)
        before=len(self.backend.matching_requests('/session/connect'))
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            _,o,_=self.request('GET','/transport/status')
            if not o.get('checking'):break
            time.sleep(.05)
        posts=[r for r in self.backend.matching_requests('/webhook') if r[0]=='POST'];self.assertTrue(posts)
        self.assertEqual(set(posts[-1][2]['events']),set(events));self.assertEqual(posts[-1][2]['webhookurl'],callback)
        self.assertEqual(o['repair'],'registered-not-reachability-tested');self.assertEqual(len(self.backend.matching_requests('/session/connect')),before)
    def test_z_different_callback_not_replaced_implicitly(self):
        self.backend.responses['/webhook']=(200,{'success':True,'data':{'webhook':'https://different.example/callback','subscribe':['Message']}})
        before=len([r for r in self.backend.matching_requests('/webhook') if r[0]=='POST'])
        code,_,_=self.request('POST','/transport/repair',{'confirm':True,'replace':False});self.assertEqual(code,202)
        for _ in range(100):
            _,o,_=self.request('GET','/transport/status')
            if not o.get('checking'):break
            time.sleep(.05)
        self.assertEqual(o['repair'],'different-callback-confirmation-required')
        self.assertEqual(len([r for r in self.backend.matching_requests('/webhook') if r[0]=='POST']),before)


    def test_verified_send_contract_auth_and_single_provider_request(self):
        before=len(self.backend.matching_requests('/chat/send/text'))
        target='123456788001@lid'
        self.assertEqual(self.request('POST','/send/verified',{'to':target,'body':'fixture'},token=None)[0],401)
        self.assertEqual(len(self.backend.matching_requests('/chat/send/text')),before)
        code,body,_=self.request('POST','/send/verified',{'to':target,'body':'fixture'})
        self.assertEqual(code,200)
        self.assertEqual(body['recipient_contract'],1)
        self.assertEqual(body['accepted_chat'],target)
        self.assertEqual(self.backend.matching_requests('/chat/send/text')[-1][2]['Phone'],target)
        self.assertEqual(len(self.backend.matching_requests('/chat/send/text')),before+1)
        self.assertTrue(self.messages(target)[-1]['me'])
        self.assertEqual(self.messages(target)[-1]['delivery'],'accepted')

    def test_verified_send_invalid_namespace_cannot_reach_provider(self):
        before=len(self.backend.matching_requests('/chat/send/text'))
        for target in ('Alice','123@unknown','123@lid@lid'):
            self.assertEqual(self.request('POST','/send/verified',{'to':target,'body':'fixture'})[0],400)
        self.assertEqual(len(self.backend.matching_requests('/chat/send/text')),before)

    def test_verified_send_phone_and_lid_get_different_history_keys(self):
        for target,expected in [('123456788002@lid','123456788002@lid'),
                                ('123456788002@s.whatsapp.net','123456788002')]:
            code,body,_=self.request('POST','/send/verified',{'to':target,'body':'fixture'})
            self.assertEqual(code,200);self.assertEqual(body['accepted_chat'],expected)
        self.assertNotEqual(self.messages('123456788002@lid')[-1]['id'],self.messages('123456788002')[-1]['id'])

    def test_verified_send_rejection_does_not_create_accepted_history(self):
        self.backend.responses['/chat/send/text']=(400,{'error':'fixture rejection'})
        code,body,_=self.request('POST','/send/verified',{'to':'123456788003@lid','body':'fixture'})
        self.assertEqual(code,502);self.assertTrue(body['uncertain'])
        self.assertEqual(self.messages('123456788003@lid'),[])
