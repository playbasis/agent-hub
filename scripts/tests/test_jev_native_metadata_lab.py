import sys
import unittest
import json
import tempfile
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jev_native_metadata_lab as native


class NativeTests(unittest.TestCase):
    def test_missing_is_not_zero_and_private_fields_are_excluded(self):
        session = {'id': 's', 'provider': 'codex', 'historyComplete': False, 'title': 'secret', 'projectPath': '/secret'}
        turn = {'id': 't', 'categories': {'execution': 2}, 'status': 'observed', 'prompt': 'secret'}
        state = native.metadata(session, turn)
        self.assertEqual(state['status'], 'unknown')
        self.assertIsNone(state['toolCount'])
        self.assertIsNone(state['modelStepCount'])
        self.assertTrue(state['historyPartial'])
        self.assertNotIn('secret', str(state))

    def test_unique_stratified_selection(self):
        base = {'provider': 'codex', 'historyComplete': True}
        sessions = [dict(base, id='s', turns=[{'id': 'a', 'categories': {}, 'status': 'completed'}, {'id': 'a', 'categories': {}, 'status': 'completed'}, {'id': 'b', 'categories': {'review': 1}, 'status': 'failed'}])]
        selected = native.select({'sessions': sessions}, 2)
        self.assertEqual(len(selected), 2)
        self.assertEqual({row[3]['status'] for row in selected}, {'completed', 'failed'})

    def test_only_valid_model_names_and_partial_step_history(self):
        session = {'provider': 'claude', 'historyComplete': True}
        turn = {'categories': {}, 'model': 'claude-opus-5', 'modelStepsComplete': False,
                'modelSteps': [{'model': 'gpt-6.1-sol', 'evidence': 'private prompt'}, {'model': 'private/path'}]}
        state = native.metadata(session, turn)
        self.assertEqual(state['models'], ['claude-opus-5', 'gpt-6.1-sol'])
        self.assertEqual(state['modelStepCount'], 2)
        self.assertTrue(state['historyPartial'])
        self.assertNotIn('private', str(state))

    def test_small_local_history_is_supported_without_hardcoded_helper(self):
        payload = {'sessions': [{'id': 's', 'provider': 'codex', 'historyComplete': False,
                    'turns': [{'id': 't', 'categories': {}, 'status': 'completed'}]}]}
        with tempfile.TemporaryDirectory() as parent:
            result = mock.Mock(stdout=json.dumps(payload).encode())
            with mock.patch.object(native.subprocess, 'run', return_value=result) as run:
                self.assertEqual(native.prepare(str(Path(parent) / 'out'), limit=1, helper='/custom/bridge'), 1)
            self.assertEqual(run.call_args.args[0], ['/custom/bridge', 'activity', 'view'])

    def test_cli_analysis_requires_explicit_paths(self):
        with mock.patch.object(sys, 'argv', ['jev_native_metadata_lab.py', '--analyze-run', '/private/run']):
            with self.assertRaises(SystemExit):
                native.main()


if __name__ == '__main__':
    unittest.main()
