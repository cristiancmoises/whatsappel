#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only delivery diagnosis, including older bridges. No send/repair/connect.

Only bounded GET responses are read. Output contains no raw response, token,
URL, JID, message text, account name or QR code. A report does not prove delivery.
"""
from __future__ import annotations
import argparse
import datetime as dt
import getpass
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

reader = sibling('read-worker')
launcher = sibling('launch-whatsappel')
writer = sibling('doctor-performance')

def boolean_alias(obj, *keys):
    if not isinstance(obj, dict): return None
    values = [obj[k] for k in keys if k in obj]
    if values and all(type(v) is bool for v in values) and all(v == values[0] for v in values):
        return values[0]
    return None

def redacted_status(body):
    # Older /status wraps the provider result in {wuzapi_status,data:{data:...}}.
    node = body
    for _ in range(3):
        if isinstance(node, dict) and any(k in node for k in ('connected', 'Connected', 'loggedIn', 'LoggedIn')):
            return {'connected': boolean_alias(node, 'connected', 'Connected'),
                    'logged_in': boolean_alias(node, 'loggedIn', 'LoggedIn')}
        node = node.get('data') if isinstance(node, dict) else None
    return {'connected': None, 'logged_in': None}

def safe_get(base, token, path, timeout):
    try:
        with reader.overall_deadline(timeout):
            return reader.read_request({'url': base, 'token': token, 'path': path,
                                        'timeout': timeout, 'max_bytes': 65536})
    except Exception:
        # No raw exception can reach the report (it can contain URL/headers).
        return {'status': None, 'body': {}}

def diagnose(base, token, timeout=5, fetch=safe_get, pause=time.sleep):
    # Validate config before the first request, including allowed client origin.
    reader.validate({'url': base, 'token': token, 'path': '/health', 'timeout': timeout})
    report = {'schema': 1, 'utc': dt.datetime.now(dt.timezone.utc).isoformat(),
              'read_only': True, 'message_sent': False, 'bridge_http': None,
              'bridge_version': None, 'transport_api': False, 'connected': None,
              'logged_in': None, 'callback_state': 'unknown', 'subscription_state': 'unknown',
              'notes': ['Cached history and HTTP acceptance do not prove phone delivery.']}
    health = fetch(base, token, '/health', timeout)
    report['bridge_http'] = health.get('status')
    body = health.get('body')
    if health.get('status') != 200 or not isinstance(body, dict):
        report['notes'].append('Bridge unavailable or denied the request. Verify selected source, client origin and token locally.')
        return report
    version = body.get('version')
    if isinstance(version, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?', version):
        report['bridge_version'] = version
    if body.get('transport_api') == 1:
        report['transport_api'] = True
        status = None
        for _ in range(12):
            status = fetch(base, token, '/transport/status', timeout)
            data = status.get('body', {})
            if status.get('status') != 200 or not isinstance(data, dict) or data.get('checking') is not True: break
            pause(.5)
        data = status.get('body') if status else None
        if isinstance(data, dict) and status.get('status') == 200:
            for key in ('connected', 'logged_in'):
                report[key] = data.get(key) if type(data.get(key)) is bool else None
            for key in ('callback_state', 'subscription_state'):
                if data.get(key) in ('yes', 'no', 'unknown'): report[key] = data[key]
            for key in ('checked_age', 'webhooks_seen', 'messages_ingested', 'last_message_age'):
                value = data.get(key)
                if type(value) is int and 0 <= value <= 10**12: report[key] = value
            report['checking'] = data.get('checking') is True
        report['notes'].append('Callback registration is not a network reachability test; check new incoming events on an approved account.')
    else:
        status = fetch(base, token, '/status', timeout)
        report['provider_status_http'] = status.get('status')
        if status.get('status') == 200: report.update(redacted_status(status.get('body')))
        report['notes'].append('Older bridge: callback registration/reception cannot be diagnosed by this endpoint. Restart the updated bridge after installation.')
    if report['connected'] is False or report['logged_in'] is False:
        report['notes'].append('Provider reports an offline or logged-out session. No automatic reconnect or pairing was attempted.')
    if report['callback_state'] == 'no' or report['subscription_state'] == 'no':
        report['notes'].append('Incoming routing does not match this bridge. Review Check delivery, then explicitly authorize repair; preserve other consumers.')
    return report

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=Path.home()/'whatsappel/.env')
    p.add_argument('--url', help='Explicit client origin (not callback URL); token is never a CLI argument')
    p.add_argument('--timeout', type=float, default=5)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args(argv)
    settings = launcher.literal_environment(args.config.expanduser())
    env = launcher.account_environment(os.environ, settings)
    token = env.get('WHATSAPPEL_TOKEN') or getpass.getpass('Existing bridge token (hidden): ')
    base = args.url or env.get('WHATSAPPEL_BRIDGE_URL', launcher.DEFAULT_ORIGIN)
    report = diagnose(base, token, args.timeout)
    writer.write_report(args.output, report)
    print(json.dumps(report, indent=2))
    print('Private report: ' + str(args.output.expanduser()))
    return 0
if __name__ == '__main__':
    try: raise SystemExit(main())
    except KeyboardInterrupt: raise SystemExit(130)
    except Exception:
        print('Diagnostic stopped: check private config, explicit client origin and a new output filename. No raw credentials or provider response printed.', file=sys.stderr)
        raise SystemExit(1)
