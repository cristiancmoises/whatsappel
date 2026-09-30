# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import os
from pathlib import Path
import unittest
import tempfile
from unittest import mock
spec=importlib.util.spec_from_file_location('launcher',Path(__file__).resolve().parents[1]/'scripts/launch-whatsappel.py')
launcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(launcher)

class QuickLaunchTests(unittest.TestCase):
    def test_guix_launcher_uses_selected_profile_image_loaders(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            cache = profile / 'lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'
            cache.parent.mkdir(parents=True)
            cache.write_text('fixture loader cache')
            original = {'GUIX_GDK_PIXBUF_MODULE_FILES': '/home-cache:/system-cache',
                        'WHATSAPPEL_TOKEN': 'fixture-private-account'}
            selected = launcher.guix_pixbuf_environment(original, str(profile / 'bin/emacs'))
            self.assertEqual(selected['GUIX_GDK_PIXBUF_MODULE_FILES'], str(cache))
            self.assertEqual(selected['WHATSAPPEL_TOKEN'], 'fixture-private-account')
            self.assertEqual(original['GUIX_GDK_PIXBUF_MODULE_FILES'], '/home-cache:/system-cache')

    def test_non_guix_launcher_preserves_image_configuration(self):
        original = {'GUIX_GDK_PIXBUF_MODULE_FILES': '/existing/cache'}
        self.assertEqual(launcher.guix_pixbuf_environment(original, '/nonexistent/emacs'), original)

    def test_default_keeps_user_init(self):
        self.assertNotIn('-Q',launcher.launch_command(Path('/tmp/source'),'/usr/bin/emacs'))
    def test_quick_mode_uses_q_without_shell(self):
        argv=launcher.launch_command(Path('/tmp/with spaces'),'/usr/bin/emacs',True)
        self.assertEqual(argv[0:2],['/usr/bin/emacs','-Q'])
        self.assertIn('/tmp/with spaces/whatsapp.el',argv[-1]);self.assertNotIn('sh',argv)
    def test_quick_mode_cannot_silently_lose_init_only_credentials(self):
        with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(launcher,'literal_environment',return_value={}),mock.patch.object(launcher.shutil,'which',return_value='/usr/bin/emacs'),mock.patch.object(launcher.os,'execve') as execute:
            with self.assertRaisesRegex(ValueError,'Quick launch requires'):launcher.main(['--quick'])
            execute.assert_not_called()
    def test_quick_keeps_credentials_off_process_arguments(self):
        secret='never-in-argv'
        with mock.patch.dict(os.environ,{'WHATSAPPEL_TOKEN':secret},clear=True),mock.patch.object(launcher,'literal_environment',return_value={}),mock.patch.object(launcher.shutil,'which',return_value='/usr/bin/emacs'),mock.patch.object(launcher.os,'execve') as execute:
            launcher.main(['--quick'])
            args=execute.call_args.args
            self.assertNotIn(secret,' '.join(args[1]));self.assertEqual(args[2]['WHATSAPPEL_TOKEN'],secret)

if __name__=='__main__':unittest.main()
