# SPDX-License-Identifier: AGPL-3.0-only
"""Fixture-only actual child/network contracts, not WhatsApp delivery evidence."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
import test_delivery_worker as delivery
import test_profiles_worker as profiles

ROOT = Path(__file__).resolve().parents[1]
def local(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT/path)
    obj = importlib.util.module_from_spec(spec); spec.loader.exec_module(obj)
    return obj
send = local('rc16_send', 'scripts/send-worker.py')

class VerifiedSendTests(unittest.TestCase):
    setUp = delivery.SendWorkerTests.setUp
    tearDown = delivery.SendWorkerTests.tearDown
    run_worker = delivery.SendWorkerTests.run_worker

    def response(self, target='123456789@lid', **extra):
        obj = copy.deepcopy(delivery.GOOD)
        obj.update(recipient_contract=1, accepted_chat=target)
        obj.update(extra)
        self.server.payload = json.dumps(obj).encode()

    def verified(self, target='123456789@lid'):
        return self.run_worker(path='/send/verified', payload={'to': target, 'body':'synthetic explicit send'})

    def test_exact_lid_roundtrip_one_request_no_delivery_claim(self):
        self.response(); result = self.verified()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.server.calls), 1)
        self.assertEqual(self.server.calls[0][0], '/send/verified')
        self.assertEqual(self.server.calls[0][1]['to'], '123456789@lid')
        self.assertEqual(json.loads(result.stdout)['body']['delivery'], 'accepted')
        self.assertNotIn('delivered', result.stdout)

    def test_phone_acknowledgement_cannot_confirm_lid(self):
        self.response('123456789'); result = self.verified()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(json.loads(result.stdout)['body']['uncertain'])
        self.assertEqual(len(self.server.calls), 1)

    def test_old_route_response_without_contract_is_uncertain(self):
        result = self.verified()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.server.calls), 1)

    def test_wrong_contract_types_are_rejected(self):
        for value in (True, '1', 0, 2, None):
            with self.subTest(value=value):
                self.response(recipient_contract=value)
                self.assertNotEqual(self.verified().returncode, 0)
        self.assertEqual(len(self.server.calls), 5)

    def test_unknown_bridge_route_never_falls_back_to_legacy_send(self):
        self.server.status = 404
        result = self.verified()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('activate', json.loads(result.stdout)['body']['error'])
        self.assertEqual([call[0] for call in self.server.calls], ['/send/verified'])

    def test_explicit_phone_namespaces_match_normalized_history_key(self):
        for target in ('123456789', '123456789@s.whatsapp.net', '123456789@c.us'):
            with self.subTest(target=target):
                self.response('123456789')
                self.assertEqual(self.verified(target).returncode, 0)
                self.assertEqual(self.server.calls[-1][1]['to'], target)

    def test_explicit_plus_phone_remains_supported(self):
        self.response('+123456789')
        self.assertEqual(self.verified('+123456789').returncode,0)
        self.assertEqual(self.server.calls[0][1]['to'],'+123456789')

    def test_group_identity_preserved(self):
        self.response('123456789-123@g.us')
        self.assertEqual(self.verified('123456789-123@g.us').returncode, 0)

    def test_name_or_unknown_namespace_rejected_before_post(self):
        for target in ('Alice', 'Alice@example.org', '123@unknown', '123\n', '123@lid@lid'):
            with self.subTest(target=target):
                self.assertNotEqual(self.verified(target).returncode, 0)
        self.assertEqual(self.server.calls, [])

    def test_duplicate_contract_json_is_rejected_without_retry(self):
        self.server.payload = (json.dumps(delivery.GOOD)[:-1] +
            ',"recipient_contract":1,"recipient_contract":0,"accepted_chat":"123456789@lid"}').encode()
        self.assertNotEqual(self.verified().returncode, 0)
        self.assertEqual(len(self.server.calls), 1)

    def test_provider_rejection_status_is_useful_without_raw_body(self):
        self.server.status=502
        self.server.payload=b'{"wuzapi_status":400,"error":"PRIVATE_PROVIDER_CONTACT"}'
        result=self.verified()
        body=json.loads(result.stdout)['body']
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(body['provider_http'],400)
        self.assertIn('verify the contact identity',body['error'])
        self.assertNotIn('PRIVATE_PROVIDER_CONTACT',result.stdout+result.stderr)
        self.assertEqual(len(self.server.calls),1)

    def test_provider_error_is_redacted_one_request(self):
        self.server.status=500; self.server.payload=b'{"error":"PRIVATE_CONTACT_AND_TOKEN"}'
        result=self.verified()
        self.assertNotIn('PRIVATE_CONTACT_AND_TOKEN', result.stdout+result.stderr)
        self.assertEqual(len(self.server.calls), 1)

    def test_validated_legacy_route_still_works_for_old_explicit_integrations(self):
        result=self.run_worker()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.server.calls[0][0], '/send')

class PhotoReasonsTests(unittest.TestCase):
    def exchange(self, body):
        def request(_origin, _token, method, path, payload=None, **kw):
            if method == 'POST': return 202, {'job':'fixture:1'}
            return 200, body
        return request

    def execute(self, body):
        with patch.object(profiles.w, 'bridge_request', self.exchange(body)):
            return profiles.w.execute(profiles.control(action='avatar', jid='123456789'))

    def test_provider_failure_reason_retained_but_body_dropped(self):
        status, result=self.execute({'state':'unavailable','reason':'provider-rejected',
            'provider_http':403,'epoch':'fixture-1','token':'PRIVATE','error':'PRIVATE'})
        self.assertEqual(status, 200)
        self.assertEqual(result['reason'], 'provider-rejected')
        self.assertEqual(result['provider_http'], 403)
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_unknown_reason_not_echoed(self):
        _, result=self.execute({'state':'unavailable','reason':'PRIVATE','provider_http':'PRIVATE'})
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_cdn_policy_error_is_typed_before_socket(self):
        with patch.object(profiles.w.socket, 'getaddrinfo', side_effect=AssertionError('network should not run')):
            with self.assertRaises(profiles.w.PhotoFailure) as exc:
                profiles.w.fetch_photo('https://evil.example/private?secret=PRIVATE')
        self.assertEqual(exc.exception.reason, 'cdn-policy')
        self.assertNotIn('PRIVATE', str(exc.exception))

    def test_missing_decoder_is_specific_and_does_not_disclose_path(self):
        with patch.object(profiles.w, 'fetch_photo', return_value=profiles.png()), patch.object(profiles.w.shutil, 'which', return_value=None):
            with self.assertRaises(profiles.w.PhotoFailure) as exc:
                self.execute({'state':'ready','url':'https://pps.whatsapp.net/synthetic','epoch':'fixture-1','photo_revision':0})
        self.assertEqual(exc.exception.reason, 'decoder-unavailable')

    def test_converter_failure_is_not_network_success(self):
        with patch.object(profiles.w, 'fetch_photo', return_value=profiles.png()), \
             patch.object(profiles.w.shutil, 'which', return_value='/fixture/ffmpeg'), \
             patch.object(profiles.w, 'thumbnail', side_effect=profiles.w.Error('PRIVATE')):
            with self.assertRaises(profiles.w.PhotoFailure) as exc:
                self.execute({'state':'ready','url':'https://pps.whatsapp.net/synthetic','epoch':'fixture-1','photo_revision':0})
        self.assertEqual(exc.exception.reason, 'decoder-failed')
        self.assertNotIn('PRIVATE', str(exc.exception))

    def test_actual_failure_worker_emits_only_safe_failure_shape(self):
        with profiles.server() as srv:
            srv.custom=(200, b'{"error":"PRIVATE_SERVER_ERROR","error":"duplicate"}')
            child=profiles.child(srv, action='avatar', jid='123456789')
        self.assertNotEqual(child.returncode, 0)
        result=json.loads(child.stdout)
        self.assertEqual(result['body']['reason'], 'worker-failed')
        self.assertEqual(result['body']['state'], 'unavailable')
        self.assertNotIn(b'PRIVATE_SERVER_ERROR', child.stdout+child.stderr)
        self.assertEqual(len(srv.requests),1)

    def test_real_ffmpeg_still_prepares_image(self):
        # Genuine converter execution retained, not a fake ready image.
        data=profiles.w.thumbnail(profiles.png(16,8),96)
        self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertLess(len(data),profiles.w.MAX_PNG)

if __name__=='__main__': unittest.main()
