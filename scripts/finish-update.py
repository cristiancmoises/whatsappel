#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Audit/install -> verify disk -> optional verified user-service restart -> probe.

The default updates source but never restarts. --check is read-only. Only an
explicit --restart-local may restart the previously configured user Shepherd
service. No provider mutation, message send, session deletion or force flag.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

SERVICE = 'whatsappel-bridge'


class FinishError(Exception):
    """Constant, nonsecret operator-facing failure."""


def sibling(filename):
    spec = importlib.util.spec_from_file_location('wa_finish_' + filename.replace('-', '_'),
                                                 Path(__file__).resolve().with_name(filename + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


update = sibling('update-package')
workflow = sibling('guix-workflow')
doctor = sibling('doctor-delivery')


def installed_check(target, spec):
    """Every managed payload must match; never accept a release label alone."""
    update.no_links(target)
    missing, changed = [], []
    for entry in spec['files']:
        path = target / update.safe_relative(entry['path'])
        update.no_links(path)
        if not path.exists():
            missing.append(entry['path'])
        elif not path.is_file() or update.digest(path) != entry['after']:
            changed.append(entry['path'])
    return {'matched': not missing and not changed, 'managed_count': len(spec['files']),
            'missing_count': len(missing), 'changed_count': len(changed),
            'missing': missing[:32], 'changed': changed[:32]}


def read_bounded(path, cap=262144):
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    with os.fdopen(fd, 'rb') as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise FinishError('Nonregular process metadata refused.')
        raw = f.read(cap + 1)
    if len(raw) > cap:
        raise FinishError('Oversized process metadata refused.')
    return raw


def command(argv, timeout=15, cap=65536):
    """Bound trusted local command output and lifetime; never echo service output."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(('WHATSAPPEL_', 'WUZAPI_'))
           and not k.endswith(('_TOKEN', '_SECRET', '_PASSWORD', '_API_KEY'))}
    env['LC_ALL'] = 'C'
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=env, start_new_session=True)
    data, until = bytearray(), time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            os.set_blocking(process.stdout.fileno(), False)
            while selector.get_map() or process.poll() is None:
                remaining = until - time.monotonic()
                if remaining <= 0:
                    raise FinishError('Local service command exceeded its deadline.')
                for key, _ in selector.select(min(remaining, .1)):
                    block = os.read(key.fd, 4096)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    data.extend(block)
                    if len(data) > cap:
                        raise FinishError('Local service command exceeded its output limit.')
            return process.returncode, data.decode('utf-8', 'replace')
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        process.stdout.close()


def service_pid(herd, run=command):
    code, text = run([herd, '--log-history=0', 'status', SERVICE])
    found = re.findall(r'^\s*Main PID:\s*([0-9]+)\s*$', text, re.M)
    if code != 0 or len(found) != 1 or not 1 < int(found[0]) < 2**31:
        raise FinishError('The expected running user Shepherd service could not be identified; no guessed restart.')
    return int(found[0])


def process_environment(raw):
    result = {}
    for row in raw.split(b'\0'):
        key, sep, value = row.partition(b'=')
        if sep and key in {b'WHATSAPPEL_TOKEN', b'WHATSAPPEL_PORT', b'WHATSAPPEL_HOST'}:
            name = key.decode('ascii')
            if name in result:
                raise FinishError('Ambiguous service account environment.')
            result[name] = value.decode('utf-8', 'strict')
    return result


def local_endpoint(base):
    uri = urlsplit(base)
    if (uri.scheme != 'http' or uri.hostname not in {'127.0.0.1', '::1'}
            or uri.username is not None or uri.password is not None
            or uri.path not in ('', '/') or uri.query or uri.fragment):
        raise FinishError('Automatic restart only supports numeric loopback HTTP; remote/tunnel deployments need explicit activation.')
    port = uri.port or 80
    if not 1 <= port <= 65535:
        raise FinishError('Invalid loopback port.')
    return uri.hostname, port


def owns_listener(proc, host, port):
    """Match the process's own socket inodes to a listening loopback/bind address."""
    sockets = set()
    for path in (proc / 'fd').iterdir():
        try:
            target = os.readlink(path)
        except FileNotFoundError:
            continue
        match = re.fullmatch(r'socket:\[([0-9]+)\]', target)
        if match:
            sockets.add(match[1])
    table = 'tcp' if host == '127.0.0.1' else 'tcp6'
    allowed = {'0100007F', '00000000'} if table == 'tcp' else {
        '00000000000000000000000001000000', '00000000000000000000000000000000'}
    data = read_bounded(proc / 'net' / table, 2 * 1024 * 1024).decode('ascii')
    for line in data.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10 or fields[3] != '0A':
            continue
        address, _, hexport = fields[1].partition(':')
        if address in allowed and int(hexport, 16) == port and fields[9] in sockets:
            return True
    return False


def inspect_service(pid, target, base, token, proc_root=Path('/proc'), uid=None):
    """Observe source, account, start time and owned listener without exporting secrets."""
    uid = os.getuid() if uid is None else uid
    proc = proc_root / str(pid)
    status = read_bounded(proc / 'status').decode('ascii')
    match = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$', status, re.M)
    if not match or any(int(v) != uid for v in match.groups()):
        raise FinishError('Service UID does not match this user; restart refused.')
    before = read_bounded(proc / 'stat')
    argv = read_bounded(proc / 'cmdline').rstrip(b'\0').decode('utf-8', 'strict').split('\0')
    executable = os.path.basename(argv[0]) if argv else ''
    options = [arg for arg in argv[1:-1] if arg not in {'--no-auto-compile', '--debug', '-s'}]
    if (not re.fullmatch(r'guile(?:-[0-9.]+)?', executable) or len(argv) < 2 or options
            or argv[-1] != str(target / 'whatsappel.scm')):
        raise FinishError('Service does not directly run this source with the supported Guile invocation; restart refused.')
    settings = process_environment(read_bounded(proc / 'environ'))
    host, port = local_endpoint(base)
    configured_port = settings.get('WHATSAPPEL_PORT', '7337')
    if (not re.fullmatch(r'[0-9]{1,5}', configured_port)
            or int(configured_port) != port
            or not hmac.compare_digest(settings.get('WHATSAPPEL_TOKEN', '').encode(), token.encode())):
        raise FinishError('Service and selected client account/port differ; restart refused.')
    if not owns_listener(proc, host, port):
        raise FinishError('The verified service does not own the selected listening socket; restart refused.')
    after = read_bounded(proc / 'stat')
    # comm can contain spaces and parentheses. starttime is field 22.
    def started(raw):
        tail = raw.rpartition(b') ')[2].split()
        if len(tail) < 20 or not tail[19].isdigit():
            raise FinishError('Cannot identify process lifetime safely.')
        return int(tail[19])
    if started(before) != started(after):
        raise FinishError('Service process changed while inspecting; restart refused.')
    return {'pid': pid, 'start_ticks': started(after), 'source_verified': True,
            'account_verified': True, 'listener_verified': True}


def probe_runtime(base, token, timeout=2, fetch=None, pause=time.sleep):
    """Probe transport independently of the health advertisement, using GET only."""
    fetch = fetch or doctor.safe_get
    doctor.reader.validate({'url': base, 'token': token, 'path': '/health', 'timeout': timeout})
    report = {'bridge_http': None, 'transport_http': None, 'bridge_version': None,
              'transport_api': False, 'conflicting_versions': False, 'connected': None,
              'logged_in': None, 'callback_state': 'unknown', 'subscription_state': 'unknown'}
    health = fetch(base, token, '/health', timeout)
    report['bridge_http'] = health.get('status')
    hbody = health.get('body')
    if health.get('status') != 200 or not isinstance(hbody, dict):
        return report
    def version(value):
        return value if isinstance(value, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?', value) else None
    hv = version(hbody.get('version'))
    report['bridge_version'] = hv
    data = None
    for attempt in range(5):
        transport = fetch(base, token, '/transport/status', timeout)
        report['transport_http'] = transport.get('status')
        data = transport.get('body')
        if (transport.get('status') != 200 or not isinstance(data, dict)
                or data.get('checking') is not True or attempt == 4):
            break
        pause(.25)
    if report['transport_http'] == 200 and isinstance(data, dict):
        tv = version(data.get('version'))
        report['transport_api'] = tv is not None and type(data.get('checking')) is bool
        report['conflicting_versions'] = hv is not None and tv is not None and hv != tv
        if tv:
            report['bridge_version'] = tv
        report['checking'] = data.get('checking') is True
        for key in ('connected', 'logged_in'):
            report[key] = data.get(key) if type(data.get(key)) is bool else None
        for key in ('callback_state', 'subscription_state'):
            if data.get(key) in ('yes', 'no', 'unknown'):
                report[key] = data[key]
        for key in ('checked_age', 'webhooks_seen', 'messages_ingested', 'last_message_age'):
            value = data.get(key)
            if type(value) is int and 0 <= value <= 10**12:
                report[key] = value
    elif report['transport_http'] in (404, 405):
        status = fetch(base, token, '/status', timeout)
        if status.get('status') == 200:
            report.update(doctor.redacted_status(status.get('body')))
    return report


def expected_runtime(report, version):
    return (report.get('bridge_http') == 200 and report.get('bridge_version') == version
            and report.get('transport_api') is True and report.get('conflicting_versions') is not True)


def run_workflow(target, bundle, spec, report, *, check=False, restart=False,
                 perform_update=None, diagnose=None, inspect=None, run=command, pause=time.sleep):
    """Keep update, payload and activation checks sequential and fail-closed."""
    perform_update = perform_update or (lambda: workflow.main([str(target), '--bundle', str(bundle)]))
    diagnose = diagnose or probe_runtime
    inspect = inspect or inspect_service
    account = doctor.launcher.account_environment(os.environ, doctor.launcher.literal_environment(target / '.env'))
    token = account.get('WHATSAPPEL_TOKEN')
    base = account.get('WHATSAPPEL_BRIDGE_URL', doctor.launcher.DEFAULT_ORIGIN)
    if not token:
        raise FinishError('No external account configuration: keep init-only credentials private and use manual activation.')
    doctor.reader.validate({'url': base, 'token': token, 'path': '/health', 'timeout': 2})
    report['before'] = installed_check(target, spec)
    before_identity, herd = None, None
    if restart:
        if os.getuid() == 0:
            raise FinishError('Run this local user-service workflow without sudo/root.')
        local_endpoint(base)
        herd = shutil.which('herd')
        if not herd:
            raise FinishError('User Shepherd client is unavailable; no service change attempted.')
        before_identity = inspect(service_pid(herd, run), target, base, token)
        report['service_before'] = before_identity
    if not check:
        report['phase'] = 'auditing-and-installing'
        if perform_update() != 0:
            raise FinishError('Update did not succeed; no activation attempted.')
        report['installed'] = True
        if update.verify_bundle(bundle) != spec:
            raise FinishError('Bundle changed during the update; no activation attempted.')
    report['files'] = installed_check(target, spec)
    if not report['files']['matched']:
        report['phase'] = 'files-mismatch'
        if not check:
            raise FinishError('Installed managed files do not match the candidate; no activation attempted.')
    if restart:
        # Account changes during auditing cannot authorize a different restart.
        again = doctor.launcher.account_environment(os.environ, doctor.launcher.literal_environment(target / '.env'))
        if (again.get('WHATSAPPEL_TOKEN') != token
                or again.get('WHATSAPPEL_BRIDGE_URL', doctor.launcher.DEFAULT_ORIGIN) != base):
            raise FinishError('Account settings changed during auditing; no activation attempted.')
        current = inspect(service_pid(herd, run), target, base, token)
        if current != before_identity:
            raise FinishError('Service changed during auditing; no activation attempted.')
        if not installed_check(target, spec)['matched']:
            raise FinishError('Installed source changed before activation; restart refused.')
        report['phase'] = 'restarting-verified-service'
        report['restart_attempted'] = True
        code, _ = run([herd, 'restart', SERVICE])
        if code != 0:
            raise FinishError('Service restart failed after source installation; retain the source backup and diagnostic.')
        # A successful herd return is not yet runtime acceptance.
        for _ in range(16):
            try:
                identity = inspect(service_pid(herd, run), target, base, token)
                if identity != before_identity:
                    report['service_after'] = identity
                    break
            except (FinishError, OSError, UnicodeError, ValueError):
                pass
            pause(.25)
        else:
            raise FinishError('A new source/account/listener-matched service was not observed; activation is unverified.')
        report['service_restarted'] = True
    report['runtime'] = diagnose(base, token, timeout=2)
    if restart and inspect(service_pid(herd, run), target, base, token) != report['service_after']:
        raise FinishError('Service changed during the final runtime probe; activation is unverified.')
    report['files'] = installed_check(target, spec)
    report['runtime_verified'] = report['files']['matched'] and expected_runtime(report['runtime'], spec['version'])
    report['delivery_registration_verified'] = (report['runtime'].get('connected') is True
        and report['runtime'].get('logged_in') is True
        and report['runtime'].get('callback_state') == 'yes'
        and report['runtime'].get('subscription_state') == 'yes')
    if report['runtime_verified']:
        report['phase'] = 'runtime-verified'
    elif report['files']['matched']:
        report['phase'] = 'installed-not-active'
    return 0 if report['runtime_verified'] else 2


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('target', nargs='?', type=Path, default=Path.home() / 'whatsappel')
    p.add_argument('--bundle', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--check', action='store_true', help='Inspect files and GET status only; do not audit/install/restart')
    p.add_argument('--restart-local', action='store_true', help='After successful full audits/install, restart only the verified user Shepherd service')
    p.add_argument('--output', type=Path, help='New private JSON file; an existing report is never overwritten')
    args = p.parse_args(argv)
    if args.check and args.restart_local:
        p.error('--check cannot restart a service')
    target, bundle = args.target.expanduser().absolute(), args.bundle.expanduser().absolute()
    report = {'schema': 1, 'utc': dt.datetime.now(dt.timezone.utc).isoformat(),
              'phase': 'preflight', 'installed': False, 'read_only': args.check,
              'restart_attempted': False, 'service_restarted': False, 'runtime_verified': False,
              'message_sent': False, 'provider_settings_changed': False,
              'note': 'Runtime version and registration are not proof of callback reachability or recipient delivery.'}
    destination = args.output.expanduser().absolute() if args.output else None
    try:
        update.no_links(target)
        if not args.check and os.getuid() == 0:
            raise FinishError('Run the workstation update without sudo/root.')
        spec = update.verify_bundle(bundle)
        if not re.fullmatch(r'\d+\.\d+\.\d+-rc\d+', spec['version']):
            raise FinishError('Invalid package version.')
        report['expected_version'] = spec['version']
        if destination:
            update.no_links(destination)
            if destination.exists() or destination == target or target in destination.parents or bundle in destination.parents:
                raise FinishError('Choose a new report path outside the installation and bundle.')
        else:
            directory = Path(tempfile.mkdtemp(prefix='whatsappel-activation-', dir=target.parent))
            destination = directory / 'report.json'
        code = run_workflow(target, bundle, spec, report, check=args.check, restart=args.restart_local)
    except KeyboardInterrupt:
        report['error'] = 'Interrupted. Source may already be installed; inspect the recorded phase before another action.'
        code = 130
    except Exception as exc:
        report['error'] = str(exc) if isinstance(exc, FinishError) else 'Validation or local operation failed; no unverified activation is authorized.'
        code = 1
    if destination and not destination.exists():
        try:
            doctor.writer.write_report(destination, report)
            print('Private activation report: ' + str(destination))
        except Exception:
            print('Could not write the private activation report.', file=sys.stderr)
            code = 1
    print(json.dumps(report, indent=2))
    if code == 0:
        print('Disk and live bridge version verified. Save work and fully restart Emacs/its daemon, then inspect Check delivery.')
    elif code == 2:
        print('Runtime not verified. Inspect phase/files/runtime; do not reset pairing or resend uncertain messages.')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
