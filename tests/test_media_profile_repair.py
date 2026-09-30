# SPDX-License-Identifier: AGPL-3.0-only
"""RC18: real child/loopback HTTP tests; CDN socket mocking is explicit.

No production accounts, external CDN, live presence or message send is used.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch, MagicMock
from test_profiles_worker import server, png, metadata, control, w as profile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('download_rc18', ROOT/'scripts/download-worker.py')
download = importlib.util.module_from_spec(spec); spec.loader.exec_module(download)
spec = importlib.util.spec_from_file_location('send_rc18', ROOT/'scripts/send-worker.py')
send = importlib.util.module_from_spec(spec); spec.loader.exec_module(send)
TOKEN = 'synthetic-profile-token-not-a-real-account'


def download_spec(**extra):
    return {'url': 'http://127.0.0.1:7337', 'token': TOKEN, 'timeout': 2,
            'path': '/download?async=1', 'payload': {'kind': 'image', 'MediaKey': 'QUJD',
               'DirectPath': '/synthetic/test', 'FileLength': 24}, **extra}


def run_child(srv, **extra):
    return subprocess.run([sys.executable, '-I', str(ROOT/'scripts/download-worker.py')],
        input=json.dumps(download_spec(url=f'http://127.0.0.1:{srv.server_port}', **extra)).encode(),
        capture_output=True, timeout=6, env={**os.environ, 'HTTP_PROXY': 'http://127.0.0.1:1',
                                           'http_proxy': 'http://127.0.0.1:1'})


class DownloadControlTests(unittest.TestCase):
    def test_only_fixed_download_paths(self):
        for path in ['/send', '/send/verified', '/profile/request', '/download?url=http://evil',
                     '//evil/download', '/download?async=2']:
            with self.subTest(path=path), self.assertRaises(download.Error):
                download.validate(download_spec(path=path))

    def test_rejects_extra_metadata_and_invalid_types(self):
        for data in [{'kind':'image','command':'id'}, {'kind':'text'}, {'kind':'image','MediaKey':True},
                     {'kind':'image','FileLength':True}, {'kind':'image','Url':'x\nCookie: secret'},
                     {'kind':'image','MediaKey':'x'*257}]:
            with self.subTest(data=data),self.assertRaises(download.Error):
                download.validate(download_spec(payload=data))

    def test_remote_cleartext_and_credentials_refused(self):
        for url in ['http://example.invalid', 'https://name:password@example.invalid',
                    'https://example.invalid/private']:
            with self.subTest(url=url),self.assertRaises(download.Error):
                download.validate(download_spec(url=url))

    def test_limits_have_no_boolean_alias(self):
        for value in [True, 0, download.MAX_REPLY+1]:
            with self.assertRaises(download.Error): download.validate(download_spec(max_bytes=value))

    def test_file_length_preserves_string_form(self):
        s=download_spec(payload={'kind':'image', 'FileLength':'24'})
        self.assertEqual(download.validate(s)[-1]['FileLength'], '24')


class DownloadHTTPTests(unittest.TestCase):
    def test_actual_child_posts_once_and_keeps_job(self):
        with server() as srv:
            srv.custom=(202, {'job':'123-456-789:1:media'})
            out=run_child(srv)
            self.assertEqual(out.returncode,0,out.stderr)
            self.assertEqual(json.loads(out.stdout)['body']['job'],'123-456-789:1:media')
            self.assertEqual(len(srv.requests),1)
            method,path,data,headers=srv.requests[0]
            self.assertEqual((method,path),('POST','/download?async=1'))
            self.assertEqual(json.loads(data),download_spec()['payload'])
            self.assertEqual(headers['X-Whatsappel-Token'],TOKEN)

    def test_actual_legacy_reply_preserves_media_bytes(self):
        raw=png(); uri='data:image/png;base64,'+base64.b64encode(raw).decode()
        body={'wuzapi_status':200, 'data':{'success':True, 'data':{'Data':uri}}}
        with server() as srv:
            srv.custom=(200,body);out=run_child(srv,path='/download')
            self.assertEqual(json.loads(out.stdout)['body'],body)
            self.assertEqual(len(srv.requests),1)

    def test_actual_http_failures_are_typed_and_redacted(self):
        for status,reason in [(401,'bridge-auth'),(403,'bridge-auth'),(404,'bridge-route'),
                              (429,'media-busy'),(413,'media-limit'),(400,'media-metadata')]:
            with self.subTest(status=status),server() as srv:
                srv.custom=(status, {'error':'PRIVATE_TOKEN_PHONE_CONTENT'})
                out=run_child(srv); obj=json.loads(out.stdout)
                self.assertEqual(obj['status'],status)
                self.assertEqual(obj['body']['reason'],reason)
                self.assertNotIn(b'PRIVATE',out.stdout)
                self.assertEqual(len(srv.requests),1)

    def test_provider_failure_preserves_only_integer_status(self):
        with server() as srv:
            srv.custom=(502,{'wuzapi_status':401,'data':{'secret':'PRIVATE'}})
            out=run_child(srv); obj=json.loads(out.stdout)
            self.assertEqual(obj['body']['reason'],'provider-auth')
            self.assertEqual(obj['body']['wuzapi_status'],401)
            self.assertNotIn(b'PRIVATE',out.stdout)

    def test_actual_redirect_is_not_followed(self):
        with server() as srv:
            srv.custom=(302, {'redirect':'PRIVATE'})
            out=run_child(srv)
            self.assertEqual(json.loads(out.stdout)['status'],302)
            self.assertEqual(len(srv.requests),1)
            self.assertNotIn(b'PRIVATE',out.stdout)

    def test_duplicate_keys_rejected(self):
        with server() as srv:
            srv.custom=(202,b'{"job":"one","job":"two"}')
            out=run_child(srv)
            self.assertNotEqual(out.returncode,0)
            self.assertIsNone(json.loads(out.stdout)['status'])

    def test_missing_or_hostile_job_rejected(self):
        for value in [None,'../secret','a'*161]:
            with self.subTest(value=value),server() as srv:
                srv.custom=(202,{'job':value});out=run_child(srv)
                self.assertNotEqual(out.returncode,0)
                self.assertEqual(len(srv.requests),1)

    def test_oversized_reply_fails_without_second_post(self):
        with server() as srv:
            srv.custom=(200,{'data':'a'*500});out=run_child(srv,max_bytes=128)
            self.assertNotEqual(out.returncode,0)
            self.assertEqual(len(srv.requests),1)

    def test_real_deadline_without_retry(self):
        with server() as srv:
            srv.delay=1.6;srv.custom=(202,{'job':'fixture:1:media'})
            start=time.monotonic();out=run_child(srv,timeout=1)
            self.assertLess(time.monotonic()-start,4)
            self.assertNotEqual(out.returncode,0)
            self.assertEqual(len(srv.requests),1)


class ProfileRepairTests(unittest.TestCase):
    def fetch(self,mime,raw):
        # Only the network connection is mocked; byte framing/header checks are real.
        response=MagicMock();response.__enter__.return_value=response;response.status=200
        response.headers.get_all.side_effect=lambda n,d=[]: [str(len(raw))] if n=='Content-Length' else d
        response.getheader.side_effect=lambda n,d='': mime if n=='Content-Type' else d
        response.read.return_value=raw
        conn=MagicMock();conn.getresponse.return_value=response
        with patch.object(profile,'PinnedHTTPS',return_value=conn),patch.object(profile,'resolve_cdn',return_value=()):
            out=profile.fetch_photo('https://pps.whatsapp.net/synthetic')
        self.assertNotIn(TOKEN,str(conn.request.call_args)); conn.close.assert_called_once()
        return out

    def test_generic_png_content_type_has_magic_validation(self):
        self.assertEqual(self.fetch('application/octet-stream',png()),png())

    def test_missing_content_type_valid_png(self):
        self.assertEqual(self.fetch('',png()),png())

    def test_active_document_type_refused_even_for_png_bytes(self):
        with self.assertRaises(profile.Error):self.fetch('text/html',png())

    def test_generic_invalid_magic_refused(self):
        with self.assertRaises(profile.Error):self.fetch('application/octet-stream',b'<html>PRIVATE</html>')

    def test_declared_jpeg_cannot_hide_png(self):
        with self.assertRaises(profile.Error):self.fetch('image/jpeg',png())

    def test_actual_bridge_auth_error_category(self):
        with server() as srv:
            srv.custom=(401,{'error':'PRIVATE'})
            status,body=profile.execute(control(url=f'http://127.0.0.1:{srv.server_port}'))
            self.assertEqual(status,401);self.assertEqual(body['reason'],'bridge-auth')
            self.assertNotIn('PRIVATE',str(body))

    def test_actual_bridge_busy_category(self):
        with server() as srv:
            srv.custom=(429,{'error':'PRIVATE'})
            status,body=profile.execute(control(action='avatar',jid='123456789',url=f'http://127.0.0.1:{srv.server_port}'))
            self.assertEqual((status,body['reason']),(429,'bridge-busy'))
            self.assertEqual(len(srv.requests),1)

    def test_last_seen_observation_does_not_make_unknown_offline(self):
        m=metadata();m['profiles'][0]['last_seen_observed']=int(time.time())-100
        out=profile.validate_snapshot(m,['123456789'])['profiles'][0]
        self.assertEqual(out['availability'],'unknown')
        self.assertEqual(out['last_seen_observed'],m['profiles'][0]['last_seen_observed'])
        self.assertNotIn('last_seen',out)

    def test_observation_rejects_forged_future_boolean_and_groups(self):
        for value in [True,0,-1,int(time.time())+1000]:
            m=metadata();m['profiles'][0]['last_seen_observed']=value
            with self.assertRaises(profile.Error):profile.validate_snapshot(m,['123456789'])
        m=metadata('123456789@g.us');m['profiles'][0]['last_seen_observed']=1
        with self.assertRaises(profile.Error):profile.validate_snapshot(m,['123456789@g.us'])

    def test_live_last_seen_contract_is_not_relaxed(self):
        m=metadata();m['profiles'][0]['last_seen']=1
        with self.assertRaises(profile.Error):profile.validate_snapshot(m,['123456789'])

    def test_profile_event_registration_needs_typed_explicit_consent(self):
        for value in ['true',1,None]:
            with self.assertRaises(ValueError):
                send.validate({'url':'http://127.0.0.1:7337','token':TOKEN,'path':'/transport/repair',
                               'payload':{'confirm':True,'profiles':value}})
        result=send.validate({'url':'http://127.0.0.1:7337','token':TOKEN,'path':'/transport/repair',
                            'payload':{'confirm':True,'profiles':True}})
        self.assertTrue(result[-1]['profiles'])

    def test_original_callback_repair_contract_remains_valid(self):
        result=send.validate({'url':'http://127.0.0.1:7337','token':TOKEN,'path':'/transport/repair',
                            'payload':{'confirm':True,'replace':False}})
        self.assertNotIn('profiles',result[-1])


if __name__=='__main__': unittest.main()
