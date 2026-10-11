"""Fixed promotion gates. These tests are snapshotted outside candidate write scope."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('heal_host', ROOT/'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.base = self.root/'base'
        self.candidate = self.root/'candidate'
        for root in (self.base, self.candidate):
            (root/'heal/baml_src').mkdir(parents=True)
            (root/'heal/baml_src/main.baml').write_text('original')
            (root/'heal/host.py').write_text('fixed supervisor')

    def tearDown(self):
        self.temp.cleanup()

    def test_only_baml_repair_is_accepted(self):
        (self.candidate/'heal/baml_src/main.baml').write_text('repaired')
        self.assertEqual(host.validate_changes(self.base, self.candidate), ['heal/baml_src/main.baml'])
        (self.candidate/'heal/host.py').write_text('weakened gate')
        with self.assertRaises(RuntimeError):
            host.validate_changes(self.base, self.candidate)

    def test_symlink_escape_is_rejected(self):
        (self.candidate/'heal/baml_src/link.baml').symlink_to(self.base/'heal/host.py')
        with self.assertRaises(RuntimeError):
            host.validate_changes(self.base, self.candidate)

    def test_post_test_modification_changes_digest(self):
        tested = host.digest(self.candidate)
        (self.candidate/'heal/baml_src/main.baml').write_text('untested')
        self.assertNotEqual(tested, host.digest(self.candidate))

    def test_secrets_are_not_passed_to_agent(self):
        with patch.dict(os.environ, {'BOUNDARY_API_KEY': 'secret', 'WORKOS_API_KEY': 'secret'}):
            env = host.clean_env()
            self.assertEqual(env['BOUNDARY_API_KEY'], 'local')
            self.assertNotIn('WORKOS_API_KEY', env)

    def test_remote_trace_endpoint_is_refused(self):
        with self.assertRaises(RuntimeError):
            host.scan({'studio_url': 'https://example.com'}, self.root)

    def test_cannot_skip_tests_to_promote(self):
        cycle = self.root/'cycle'
        cycle.mkdir()
        host.save(self.root/'config.json', {})
        host.save(cycle/'journal.json', {'base': str(self.base), 'phase': 'fixed'})
        with patch.dict(os.environ, HEAL_STATE=str(self.root), HEAL_CYCLE=str(cycle)):
            with self.assertRaises(RuntimeError):
                host.operation('promote')

    def test_failed_tests_do_not_approve_release(self):
        cycle = self.root/'cycle'
        cycle.mkdir()
        self.candidate.rename(cycle/'candidate')
        (cycle/'candidate/heal/baml_src/main.baml').write_text('repair')
        host.save(self.root/'config.json', {})
        host.save(cycle/'journal.json', {'base': str(self.base), 'phase': 'fixed'})
        with patch.dict(os.environ, HEAL_STATE=str(self.root), HEAL_CYCLE=str(cycle)):
            with patch.object(host, 'baml', side_effect=RuntimeError('tests failed')):
                with self.assertRaises(RuntimeError):
                    host.operation('test')
        self.assertEqual(host.read(cycle/'journal.json')['phase'], 'fixed')

class BamlFlowTests(unittest.TestCase):
    def exercise(self, diagnosis='repair', fail_test=False):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root/'calls'
            fake = root/'host.py'
            fake.write_text('''import os, sys
from pathlib import Path
op = sys.argv[2]
p = Path(os.environ['FAKE_CALLS'])
with p.open('a') as f: f.write(op+'\\n')
if op == 'test' and os.environ['FAKE_FAIL'] == 'yes': sys.exit(1)
print({'diagnose': os.environ['FAKE_DIAGNOSIS'], 'fix': 'fixed'}.get(op, 'ok'))
''')
            candidate = os.environ.get('HEAL_CANDIDATE')
            project = Path(candidate)/'heal' if candidate else ROOT
            env = host.clean_env()
            env.update(HEAL_HOST=str(fake), FAKE_CALLS=str(calls),
                       FAKE_DIAGNOSIS=diagnosis, FAKE_FAIL='yes' if fail_test else 'no')
            result = subprocess.run(['baml', '--agent-skill-check', 'off', 'run', 'main'],
                                    cwd=project, env=env, capture_output=True, timeout=30)
            return result.returncode, calls.read_text().splitlines()

    def test_real_baml_orders_agents_tests_and_promotion(self):
        code, calls = self.exercise()
        self.assertEqual(code, 0)
        self.assertEqual(calls, ['scan', 'diagnose', 'fix', 'test', 'promote'])

    def test_no_finding_does_not_spawn_fixer(self):
        code, calls = self.exercise(diagnosis='none')
        self.assertEqual(code, 0)
        self.assertEqual(calls, ['scan', 'diagnose'])

    def test_test_failure_prevents_promotion(self):
        code, calls = self.exercise(fail_test=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, ['scan', 'diagnose', 'fix', 'test'])



class DisabledExecutionTests(unittest.TestCase):
    def test_entrypoints_refuse_before_starting_processes(self):
        with patch.object(host.subprocess, 'run') as run, patch.object(host.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(RuntimeError, 'disabled'):
                host.operation('test')
            with self.assertRaisesRegex(RuntimeError, 'disabled'):
                host.supervise(None)
            run.assert_not_called()
            popen.assert_not_called()

if __name__ == '__main__':
    unittest.main()
