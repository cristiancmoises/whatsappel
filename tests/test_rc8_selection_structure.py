# SPDX-License-Identifier: AGPL-3.0-only
"""Static call-path guards, explicitly NOT native Emacs behavioral tests."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rc8_structure', ROOT / 'scripts/check-lisp-structure.py')
syntax = importlib.util.module_from_spec(spec)
spec.loader.exec_module(syntax)
FORMS = syntax.read((ROOT / 'whatsapp.el').read_text())
DEFS = {str(f[1]): f for f in FORMS if isinstance(f, syntax.Form) and len(f) > 1 and f[0] == 'defun'}

def calls(form):
    if not isinstance(form, syntax.Form) or not form:
        return set()
    if form[0] in ('quote', 'quasiquote'):
        return set()
    found = {str(form[0])} if isinstance(form[0], syntax.Atom) else set()
    for child in form:
        found.update(calls(child))
    return found

class SelectionStructure(unittest.TestCase):
    def test_new_forms_have_balanced_binding_shapes(self):
        self.assertEqual(syntax.shapes(FORMS), [])
        self.assertEqual(syntax.shapes(syntax.read((ROOT / 'tests/selection-tests.el').read_text())), [])

    def test_selection_has_no_direct_refresh_or_decoder_call(self):
        self.assertFalse({'whatsapp-chat-refresh', 'whatsapp-pq-open', 'whatsapp--preview-image',
                          'url-retrieve-synchronously', 'call-process'} & calls(DEFS['whatsapp-open-chat']))
        self.assertIn('run-at-time', calls(DEFS['whatsapp-open-chat']))

    def test_pq_render_is_cache_only(self):
        self.assertFalse({'whatsapp-pq-open', 'whatsapp-pq-ready-p', 'whatsapp-pq-have-contact-p',
                          'call-process', 'file-exists-p'} & calls(DEFS['whatsapp--insert-pq']))

    def test_image_renderer_cannot_start_new_decoder(self):
        self.assertNotIn('whatsapp--preview-image', calls(DEFS['whatsapp--insert-image']))
        self.assertNotIn('whatsapp--data-uri-bytes', calls(DEFS['whatsapp--insert-image']))

    def test_scroll_scheduler_uses_wall_clock(self):
        self.assertIn('run-at-time', calls(DEFS['whatsapp-chat--schedule-prefetch']))
        self.assertNotIn('run-with-idle-timer', calls(DEFS['whatsapp-chat--schedule-prefetch']))

    def test_root_selection_does_not_delete_rows(self):
        self.assertFalse({'erase-buffer', 'delete-region', 'whatsapp-root--render',
                          'whatsapp-root--insert-row'} & calls(DEFS['whatsapp-root--select-only']))

    def test_native_selection_suite_is_not_omitted_from_audit(self):
        spec = importlib.util.spec_from_file_location('rc8_audit', ROOT / 'scripts/audit-workspace.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        plan = dict(module.checks(ROOT, 'full'))
        self.assertIn('tests/selection-tests.el', plan['emacs-ert'])
        self.assertIn('tests/selection-tests.el', plan['lisp-structure-only'])

    def test_decrypt_keeps_age_check_and_has_no_send_endpoint(self):
        text = (ROOT / 'whatsapp.el').read_text()
        begin = text.index('(defun whatsapp-chat-decrypt ')
        end = text.index('(defun whatsapp-chat-send-encrypted', begin)
        self.assertIn('"--max-age"', text[begin:end])
        self.assertNotIn('"/send', text[begin:end])
        self.assertIn('make-process', calls(DEFS['whatsapp-chat-decrypt']))
        self.assertNotIn('call-process', calls(DEFS['whatsapp-chat-decrypt']))

if __name__ == '__main__':
    unittest.main()
