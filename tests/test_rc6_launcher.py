# SPDX-License-Identifier: AGPL-3.0-only
"""Private config tests exercise the actual descriptor, not shell evaluation."""
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rc6_launcher', ROOT / 'scripts/launch-whatsappel.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)

class PrivateConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / '.env'

    def write(self, text='WHATSAPPEL_TOKEN="fixture-token"\n', mode=0o600):
        self.path.write_text(text)
        self.path.chmod(mode)
        return self.path

    def test_absent_file_allows_init_only_configuration(self):
        self.assertEqual(launcher.literal_environment(self.path), {})

    def test_private_file_and_literal_unicode_accepted(self):
        self.write('WHATSAPPEL_TOKEN="fixture-café"\n')
        self.assertEqual(launcher.literal_environment(self.path)['WHATSAPPEL_TOKEN'], 'fixture-café')

    def test_owner_read_only_file_accepted(self):
        self.write(mode=0o400)
        self.assertEqual(launcher.literal_environment(self.path)['WHATSAPPEL_TOKEN'], 'fixture-token')

    def test_world_readable_file_rejected(self):
        self.write(mode=0o644)
        with self.assertRaisesRegex(ValueError, 'chmod 600'):
            launcher.literal_environment(self.path)

    def test_group_readable_file_rejected(self):
        self.write(mode=0o640)
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_world_writable_file_rejected(self):
        self.write(mode=0o622)
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_symlink_file_rejected(self):
        original = self.write()
        link = original.with_name('link')
        link.symlink_to(original)
        with self.assertRaises(ValueError):
            launcher.literal_environment(link)

    def test_dangling_symlink_not_treated_as_missing_configuration(self):
        self.path.symlink_to(self.path.with_name('missing'))
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_fifo_refused_without_waiting_for_writer(self):
        os.mkfifo(self.path, 0o600)
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_directory_is_not_configuration(self):
        self.path.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_different_owner_rejected(self):
        self.write()
        real = os.fstat
        def other_owner(fd):
            st = real(fd)
            return mock.Mock(st_mode=st.st_mode, st_uid=os.getuid()+1, st_size=st.st_size)
        with mock.patch.object(launcher.os, 'fstat', side_effect=other_owner):
            with self.assertRaises(ValueError):
                launcher.literal_environment(self.path)

    def test_oversized_file_rejected(self):
        self.write('#' * 65537)
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_descriptor_is_bounded_even_if_size_metadata_lies(self):
        self.write('#' * 65537)
        real = os.fstat
        def stale_size(fd):
            st = real(fd)
            return mock.Mock(st_mode=st.st_mode, st_uid=st.st_uid, st_size=0)
        with mock.patch.object(launcher.os, 'fstat', side_effect=stale_size):
            with self.assertRaises(ValueError):
                launcher.literal_environment(self.path)

    def test_duplicate_whitelisted_assignments_rejected(self):
        self.write('WHATSAPPEL_TOKEN=first\nWHATSAPPEL_TOKEN=second\n')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            launcher.literal_environment(self.path)

    def test_malformed_utf8_error_does_not_reveal_bytes(self):
        self.path.write_bytes(b'WHATSAPPEL_TOKEN=fixture-secret\xff')
        self.path.chmod(0o600)
        with self.assertRaises(ValueError) as context:
            launcher.literal_environment(self.path)
        self.assertNotIn('fixture-secret', str(context.exception))

    def test_shell_substitution_rejected_without_execution(self):
        target = self.path.with_name('SHOULD_NOT_EXIST')
        self.write('WHATSAPPEL_TOKEN="$(touch '+str(target)+')"\n')
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)
        self.assertFalse(target.exists())

    def test_literal_control_character_rejected(self):
        self.write('WHATSAPPEL_TOKEN="fixture\ttoken"\n')
        with self.assertRaises(ValueError):
            launcher.literal_environment(self.path)

    def test_invalid_quotation_error_is_redacted(self):
        self.write('WHATSAPPEL_TOKEN="fixture-secret\n')
        with self.assertRaises(ValueError) as context:
            launcher.literal_environment(self.path)
        self.assertNotIn('fixture-secret', str(context.exception))

    def test_callback_url_is_not_a_client_origin(self):
        self.write('WHATSAPPEL_TOKEN=fixture\nWHATSAPPEL_PUBLIC_URL=http://127.0.0.1:7337\n')
        value = launcher.literal_environment(self.path)
        self.assertNotIn('WHATSAPPEL_BRIDGE_URL', value)
        with self.assertRaises(ValueError):
            launcher.account_environment({}, value)

    def test_explicit_bridge_url_wins_over_webhook_url(self):
        self.write('WHATSAPPEL_BRIDGE_URL=http://127.0.0.1:17337\nWHATSAPPEL_PUBLIC_URL=http://127.0.0.1:7337\n')
        self.assertEqual(launcher.literal_environment(self.path)['WHATSAPPEL_BRIDGE_URL'], 'http://127.0.0.1:17337')

    def test_unknown_assignments_never_evaluated_or_exported(self):
        self.write('UNRELATED=$(false)\nWHATSAPPEL_TOKEN=fixture\n')
        self.assertEqual(launcher.literal_environment(self.path), {'WHATSAPPEL_TOKEN':'fixture'})

    def test_open_uses_nofollow_and_nonblock(self):
        self.write()
        real = os.open
        with mock.patch.object(launcher.os, 'open', side_effect=real) as opened:
            launcher.literal_environment(self.path)
        flags = opened.call_args.args[1]
        self.assertTrue(flags & os.O_NOFOLLOW)
        self.assertTrue(flags & os.O_NONBLOCK)

if __name__ == '__main__':
    unittest.main()
